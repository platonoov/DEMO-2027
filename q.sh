#!/usr/bin/env bash
# DEMO-2027.sh — Proxmox VE stand manager
# Persistent isolated Linux bridges, per-stand VMs/pools/users, ownership manifest.
set -Eeuo pipefail
exec python3 - "$@" <<'PY'
import os, sys, re, json, shlex, shutil, subprocess, urllib.parse, urllib.request, getpass, secrets, string, time, tempfile, atexit
from pathlib import Path

# The Python program is embedded in a Bash heredoc, so stdin contains this
# source code rather than interactive answers. Read menu answers from the
# controlling terminal instead (works with: bash <(curl ...)).
try:
    sys.stdin = open('/dev/tty', 'r', encoding='utf-8', errors='replace')
except OSError:
    print('ОШИБКА: нет доступа к терминалу для ввода. Запусти скрипт из интерактивной консоли Proxmox.', file=sys.stderr)
    sys.exit(1)

APP = 'DEMO-2027'
CONF_URL = 'https://raw.githubusercontent.com/platonoov/DEMO-2027/main/conf.txt'
STATE = Path('/var/lib/demo-2027')
STANDS = STATE / 'stands'
NETDIR = Path('/etc/network/interfaces.d')
INTERFACES = Path('/etc/network/interfaces')

class Failure(Exception): pass

def run(args, check=True, capture=True, input_text=None):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.PIPE if capture else None, input=input_text)
    if check and p.returncode:
        msg = (p.stderr or p.stdout or '').strip()
        raise Failure(f"Команда завершилась с кодом {p.returncode}: {shlex.join(args)}\n{msg}")
    return p

def yesno(prompt, default=False):
    suffix = '[Y/n]' if default else '[y/N]'
    v = input(f'{prompt} {suffix}: ').strip().lower()
    return default if not v else v in ('y','yes','д','да')

def need_root():
    if os.geteuid() != 0: raise Failure('Запусти скрипт от root: bash DEMO-2027.sh')
    for c in ('qm','pvesh','pvesm','pveum','ip','python3'):
        if not shutil.which(c): raise Failure(f'Не найдена команда {c}. Скрипт рассчитан на Proxmox VE.')

def read_conf(path):
    p = Path(path).expanduser()
    if not p.is_file(): raise Failure(f'Не найден conf.txt: {p}')
    raw = p.read_text(encoding='utf-8')
    # Parse only known assignment blocks; never source/evaluate conf.txt as shell.
    blocks = {}
    pat = re.compile(r"^\s*(config_templates|config_stand_1_var|config_stand_2_var)\[([^\]]+)\]\s*=\s*'\s*\n(.*?)\n\s*'\s*$", re.M|re.S)
    for m in pat.finditer(raw):
        group, key, body = m.groups()
        vals = {}
        for line in body.splitlines():
            line=line.strip()
            if not line or line.startswith('#') or '=' not in line: continue
            k,v=line.split('=',1); vals[k.strip()] = v.strip()
        blocks[(group,key)] = vals
    templates = {k[1]:v for k,v in blocks.items() if k[0]=='config_templates'}
    mods = {1:{},2:{}}
    for n in (1,2):
        for (g,k),v in blocks.items():
            if g == f'config_stand_{n}_var': mods[n][k]=v
    if not templates or not mods[1] or not mods[2]:
        raise Failure('Не удалось разобрать conf.txt. Проверь формат блоков config_templates/config_stand_*_var.')
    return raw, templates, mods

def parse_startup(v):
    m = re.search(r'order\s*=\s*(\d+)',v or '')
    return int(m.group(1)) if m else 99

def net_values(v):
    v = v.strip()
    opts={}
    for k,val in re.findall(r'([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*("[^"]*"|[^,}\s]+)', v):
        opts[k.strip()] = val.strip().strip('"')
    logical = None
    if 'bridge' in opts:
        b=opts['bridge'].strip()
        if b == 'inet': opts['external']='1'
        else:
            m=re.search(r':\s*([A-Za-z0-9_.-]+)', b)
            if m: logical=m.group(1)
            elif b.startswith(':'): logical=b[1:].strip()
            elif b: logical=b
    if logical is None:
        m=re.match(r'^\s*:\s*([A-Za-z0-9_.-]+)',v)
        if m: logical=m.group(1)
        else:
            m=re.search(r':\s*([A-Za-z0-9_.-]+)',v)
            if m: logical=m.group(1)
    return opts, logical

def get_net_specs(tpl, vm):
    raw={}
    for source in (tpl,vm):
        for k,v in source.items():
            m=re.fullmatch(r'network_(\d+)',k)
            if m: raw[int(m.group(1))]=v
    specs=[]
    for idx,v in sorted(raw.items()):
        opts,logical=net_values(v)
        # A network without a resolvable bridge is a config error, not silently ignored.
        if not opts.get('external') and not logical:
            raise Failure(f'Не удалось распознать сеть network_{idx}: {v}')
        specs.append({'idx':idx,'raw':v,'opts':opts,'logical':logical,'external':bool(opts.get('external'))})
    return specs

def get_storage():
    p=run(['pvesm','status','--content','images']).stdout
    rows=[]
    for line in p.splitlines()[1:]:
        a=line.split()
        # pvesm status columns are: Name, Type, Status, ...
        if len(a)>=3 and a[2].lower()=='active': rows.append(a[0])
    if not rows:
        p=run(['pvesm','status']).stdout
        for line in p.splitlines()[1:]:
            a=line.split()
            if len(a)>=3 and a[2].lower()=='active': rows.append(a[0])
    rows=list(dict.fromkeys(rows))
    if not rows: raise Failure('Не найдено активное хранилище Proxmox.')
    print('\nДоступные хранилища:')
    for i,s in enumerate(rows,1): print(f'  {i}. {s}')
    while True:
        x=input('Выбери хранилище для дисков: ').strip()
        if x.isdigit() and 1<=int(x)<=len(rows): return rows[int(x)-1]
        if x in rows:return x
        print('Некорректный выбор.')

def bridge_exists(name):
    return subprocess.run(['ip','link','show','dev',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0

def source_enabled():
    if not INTERFACES.exists(): raise Failure(f'Не найден {INTERFACES}; невозможно безопасно настроить постоянные мосты.')
    text=INTERFACES.read_text(errors='replace')
    return bool(re.search(r'^\s*source(?:-directory)?\s+/etc/network/interfaces\.d(?:/\*|\s*)\s*$',text,re.M))

def ensure_network_include():
    NETDIR.mkdir(parents=True,exist_ok=True)
    text=INTERFACES.read_text(errors='replace')
    if source_enabled(): return
    # Add only a source line; preserve the existing file and create a timestamped backup.
    backup=INTERFACES.with_name('interfaces.demo-2027.bak.'+time.strftime('%Y%m%d-%H%M%S'))
    shutil.copy2(INTERFACES,backup)
    with INTERFACES.open('a',encoding='utf-8') as f:
        if text and not text.endswith('\n'): f.write('\n')
        f.write('\n# Added by DEMO-2027: persistent isolated stand bridges\nsource /etc/network/interfaces.d/*\n')
    print(f'Добавлена директива подключения сетевых файлов. Резервная копия: {backup}')

def stand_paths(module, num):
    sid=f'{"A" if module==1 else "B"}-{num}'
    d=STANDS/sid
    return sid,d,d/'manifest.json',NETDIR/f'demo-2027-{sid}.cfg'

def load_manifest(path):
    return json.loads(path.read_text())

def list_stands():
    if not STANDS.exists(): print('Реестр стендов пока пуст.'); return
    found=0
    for f in sorted(STANDS.glob('*/manifest.json')):
        try: m=load_manifest(f)
        except Exception: print(f'Повреждён манифест: {f}'); continue
        found+=1
        print(f"\n{m.get('sid')} | модуль {m.get('module')} | пул {m.get('pool')} | пользователь {m.get('user')}")
        for vm in m.get('vms',[]):
            print(f"  VMID {vm.get('vmid')}  {vm.get('name')}  ({'есть' if subprocess.run(['qm','status',str(vm['vmid'])],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0 else 'нет в PVE'})")
        print('  Мосты:', ', '.join(m.get('bridges',[])) or 'нет')
    if not found: print('Реестр стендов пока пуст.')

def all_vmids():
    out=run(['pvesh','get','/cluster/resources','--type','vm','--output-format','json']).stdout
    try: data=json.loads(out)
    except Exception: data=[]
    return {int(x['vmid']) for x in data if 'vmid' in x}

def next_vmids(module, count, existing):
    base=30000 if module==1 else 40000
    picked=[]; x=base
    while len(picked)<count:
        if x not in existing: picked.append(x)
        x+=1
        if x>59999: raise Failure('Закончился диапазон VMID, зарезервированный скриптом (30000–59999).')
    return picked

def make_bridge_name(module, num, idx):
    # Linux interface names must be <=15 chars.
    return f'd27{ "a" if module==1 else "b"}{num:02d}n{idx:02d}'

def write_bridge_config(path, bridges):
    lines=['# Managed by DEMO-2027. Do not edit manually unless you also update the stand manifest.']
    for b in bridges:
        lines += [f'auto {b}',f'iface {b} inet manual','    bridge-ports none','    bridge-stp off','    bridge-fd 0','']
    path.write_text('\n'.join(lines),encoding='utf-8')

def parse_bool(v): return str(v).strip().lower() in ('1','yes','true','on')

def download_image(spec, cache_dir):
    spec=spec.strip()
    if not spec: raise Failure('Пустой boot_disk_0.')
    if not re.match(r'^https?://',spec):
        p=Path(spec)
        if not p.is_file(): raise Failure(f'Файл образа не найден: {p}')
        return str(p)
    cache_dir.mkdir(parents=True,exist_ok=True)
    basename=Path(urllib.parse.urlparse(spec).path).name or 'disk.qcow2'
    if not basename.endswith(('.qcow2','.raw','.vmdk')): basename += '.qcow2'
    dest=cache_dir/basename
    if dest.is_file() and dest.stat().st_size>1024*1024:
        if yesno(f'Использовать уже скачанный образ {dest}?',True): return str(dest)
    # Yandex public link format /d/<public-key>/<filename>; resolve direct download URL via public API.
    parsed=urllib.parse.urlparse(spec)
    parts=[urllib.parse.unquote(x) for x in parsed.path.split('/') if x]
    direct=spec
    if 'disk.yandex.' in parsed.netloc and len(parts)>=2 and parts[0]=='d':
        public_key='https://'+parsed.netloc+'/d/'+parts[1]
        file_path='/'+'/'.join(parts[2:]) if len(parts)>2 else ''
        api='https://cloud-api.yandex.net/v1/disk/public/resources/download?'+urllib.parse.urlencode({'public_key':public_key, **({'path':file_path} if file_path else {})})
        req=urllib.request.Request(api,headers={'User-Agent':'DEMO-2027/1.0'})
        with urllib.request.urlopen(req,timeout=30) as r: payload=json.loads(r.read().decode('utf-8'))
        direct=payload['href']
    print(f'Загрузка образа: {basename}')
    tmp=dest.with_suffix(dest.suffix+'.part')
    req=urllib.request.Request(direct,headers={'User-Agent':'DEMO-2027/1.0'})
    try:
        with urllib.request.urlopen(req,timeout=60) as r, tmp.open('wb') as f:
            shutil.copyfileobj(r,f)
        if tmp.stat().st_size < 1024*1024:
            sample=tmp.read_bytes()[:300].lower()
            if b'<html' in sample or b'<!doctype' in sample: raise Failure(f'Вместо образа получена HTML-страница: {spec}')
            raise Failure(f'Скачанный файл подозрительно мал ({tmp.stat().st_size} байт): {spec}')
        tmp.replace(dest)
    except Exception:
        try: tmp.unlink()
        except OSError: pass
        raise
    return str(dest)

def make_net_arg(spec, bridge, model, mac_prefix=None):
    parts=[model,f'bridge={bridge}']
    opts=spec['opts']
    if parse_bool(opts.get('firewall','0')): parts.append('firewall=1')
    if 'tag' in opts:
        if not str(opts['tag']).isdigit(): raise Failure(f'Некорректный VLAN tag: {opts["tag"]}')
        parts.append('tag='+str(opts['tag']))
    if str(opts.get('state','')).lower()=='down': parts.append('link_down=1')
    if mac_prefix:
        pref=re.sub(r'[^0-9A-Fa-f]','',mac_prefix).upper()
        if len(pref)>=8:
            pref=pref[:8]
            parts.append('macaddr='+':'.join([pref[i:i+2] for i in range(0,8,2)]+[f'{secrets.randbelow(256):02X}',f'{secrets.randbelow(256):02X}']))
    return ','.join(parts)

def create_vm(vmid, name, tplname, tpl, vm, specs, bridges_by_logical, external, storage, image_path):
    mem=int(vm.get('memory',tpl.get('memory','1024')))
    cores=int(vm.get('cores',tpl.get('cores','1')))
    args=['qm','create',str(vmid),'--name',name,'--memory',str(mem),'--cores',str(cores),'--ostype',tpl.get('ostype','l26')]
    for key,flag in [('cpu','--cpu'),('scsihw','--scsihw'),('bios','--bios'),('machine','--machine'),('tags','--tags')]:
        if vm.get(key, tpl.get(key)): args += [flag,vm.get(key,tpl.get(key))]
    if vm.get('description'): args += ['--description',vm['description']]
    if parse_bool(vm.get('agent',tpl.get('agent','0'))): args += ['--agent','enabled=1']
    if tpl.get('serial0')=='socket': args += ['--serial0','socket']
    if parse_bool(vm.get('tablet',tpl.get('tablet','1')))==False: args += ['--tablet','0']
    startup=vm.get('startup','')
    if startup: args += ['--startup',startup]
    run(args)
    run(['qm','importdisk',str(vmid),image_path,storage,'--format','qcow2'])
    cfg=run(['qm','config',str(vmid)]).stdout
    unused=re.search(r'^unused\d+:\s*(\S+)',cfg,re.M)
    if not unused: raise Failure(f'Не удалось найти импортированный диск у VMID {vmid}.')
    disk_type=tpl.get('disk_type','scsi').lower()
    target='ide0' if disk_type=='ide' else 'scsi0'
    run(['qm','set',str(vmid),'--'+target,unused.group(1)])
    run(['qm','set',str(vmid),'--boot',f'order={target}'])
    model=tpl.get('netifs_type','virtio').lower()
    mac_prefix=tpl.get('netifs_mac')
    for spec in specs:
        bridge=external if spec['external'] else bridges_by_logical[spec['logical']]
        netarg=make_net_arg(spec,bridge,model,mac_prefix)
        run(['qm','set',str(vmid),f'--net{spec["idx"]}',netarg])
    for k,v in sorted(vm.items()):
        m=re.fullmatch(r'disk_(\d+)',k)
        if m:
            dm=re.match(r'\s*(\d+(?:\.\d+)?)\s*(GB|G|MB|M)\s*$',v,re.I)
            if not dm: raise Failure(f'Неизвестный размер {k}={v} у {name}. Используй, например, "1 GB".')
            amount=float(dm.group(1)); unit=dm.group(2).upper()
            size=f'{int(amount)}G' if unit in ('GB','G') else f'{int(amount)}M'
            slot=int(m.group(1))
            run(['qm','set',str(vmid),f'--scsi{slot}',f'{storage}:{size}'])
    # firewall_opt from the config is represented on the VM firewall options where supported.
    fw=vm.get('firewall_opt','')
    if fw and 'enable' in fw:
        enabled=re.search(r'enable\s*=\s*(\d+)',fw)
        if enabled: run(['qm','set',str(vmid),'--firewall','1' if enabled.group(1)=='1' else '0'],check=False)

def pve_user_exists(user):
    return subprocess.run(['pveum','user','list','--output-format','json'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True).returncode==0 and any(x.get('userid')==user for x in json.loads(run(['pveum','user','list','--output-format','json']).stdout))

def ensure_role(role, privs):
    existing=run(['pveum','role','list','--output-format','json']).stdout
    try: names={x.get('roleid') for x in json.loads(existing)}
    except Exception: names=set()
    if role not in names: run(['pveum','role','add',role,'--privs',privs])

def create_stand(module, num, external, storage, templates, mods):
    sid,d,manifest_path,netfile=stand_paths(module,num)
    if manifest_path.exists(): raise Failure(f'Стенд {sid} уже есть в реестре: {manifest_path}')
    if d.exists() and any(d.iterdir()): raise Failure(f'Каталог стенда {d} уже существует и не пуст.')
    cfg=mods[module]
    standcfg=cfg.get('stand_config')
    if not standcfg: raise Failure(f'В conf.txt нет stand_config для модуля {module}.')
    pool=standcfg.get('pool_name','').replace('{0}',str(num))
    userbase=standcfg.get('access_user_name','').replace('{0}',str(num))
    user=userbase if '@' in userbase else userbase+'@pve'
    vmblocks=[]
    for k,v in cfg.items():
        if re.fullmatch(r'vm_\d+',k):
            if not v.get('name') or not v.get('config_template'): raise Failure(f'{sid}: {k} не содержит name/config_template.')
            if v['config_template'] not in templates: raise Failure(f'{sid}: шаблон {v["config_template"]} отсутствует в conf.txt.')
            tpl=templates[v['config_template']]
            img=v.get('boot_disk_0',tpl.get('boot_disk_0','')).strip()
            if not img: raise Failure(f'{sid}/{v["name"]}: не задан boot_disk_0.')
            specs=get_net_specs(tpl,v)
            vmblocks.append((int(k.split('_')[1]),v,tpl,specs,img))
    if not vmblocks: raise Failure(f'Для модуля {module} не найдены виртуальные машины.')
    # Validate all local image files before changing Proxmox.
    for _,v,tpl,_,img in vmblocks:
        if not re.match(r'^https?://',img) and not Path(img).is_file(): raise Failure(f'Образ {img} для {v["name"]} не найден.')
    used=all_vmids(); vmids=next_vmids(module,len(vmblocks),used)
    # Network logical names are local to this stand; map them to unique Linux bridge names.
    logicals=[]
    for _,_,_,specs,_ in vmblocks:
        for s in specs:
            if not s['external'] and s['logical'] not in logicals: logicals.append(s['logical'])
    bridges={logical:make_bridge_name(module,num,i+1) for i,logical in enumerate(logicals)}
    for b in bridges.values():
        if bridge_exists(b): raise Failure(f'Мост {b} уже существует в системе и не принадлежит реестру DEMO-2027; отменяю создание.')
    if netfile.exists(): raise Failure(f'Сетевой файл {netfile} уже существует, но манифеста нет. Нужна ручная проверка.')
    ensure_network_include()
    STANDS.mkdir(parents=True,exist_ok=True); d.mkdir(parents=True,exist_ok=True)
    manifest={'app':APP,'sid':sid,'module':module,'number':num,'pool':pool,'user':user,'user_created':False,
              'external_bridge':external,'storage':storage,'bridges':list(bridges.values()),'logical_networks':bridges,
              'network_file':str(netfile),'vms':[],'created_at':time.strftime('%Y-%m-%dT%H:%M:%S%z'),'status':'creating'}
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
    try:
        write_bridge_config(netfile,list(bridges.values()))
        # Bring up only bridges belonging to this stand. Avoid ifreload -a so
        # the management bridge/default route are not needlessly reconfigured.
        if not shutil.which('ifup'):
            raise Failure('Не найдена команда ifup из ifupdown2; нельзя безопасно поднять постоянные мосты.')
        for b in bridges.values(): run(['ifup',b])
        for b in bridges.values():
            if not bridge_exists(b): raise Failure(f'Постоянный мост {b} не поднялся. Проверь {netfile}.')
        desc=standcfg.get('pool_desc','').replace('{0}',str(num))
        run(['pvesh','create','/pools','--pool',pool,'--comment',desc])
        role=standcfg.get('pool_access_role','Competitor_DE')
        role_privs='Pool.Audit VM.Audit VM.Console VM.PowerMgmt'
        ensure_role(role,role_privs)
        created_user=False
        generated_password=None
        if not pve_user_exists(user):
            # Proxmox VE rejects passwords shorter than 8 characters. Generate 12
            # chars from uppercase letters and digits; never persist the secret in the manifest.
            alphabet=string.ascii_uppercase + string.digits
            generated_password=''.join(secrets.choice(alphabet) for _ in range(12))
            run(['pveum','user','add',user,'--comment',standcfg.get('access_user_desc','').replace('{0}',str(num)),
                 '--password',generated_password,'--enable','1'])
            created_user=True
        else:
            print(f'Пользователь {user} уже существует; пароль не изменялся.')
        manifest['user_created']=created_user
        manifest['role']=standcfg.get('pool_access_role','Competitor_DE')
        manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
        cache=STATE/'images'
        for ix,(n,v,tpl,specs,img) in enumerate(vmblocks):
            vmid=vmids[ix]
            # Register intended VMID before creating it so interrupted operations can be audited.
            manifest['vms'].append({'vmid':vmid,'name':v['name'],'created':False})
            manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
            image_path=download_image(img,cache)
            create_vm(vmid,v['name'],v['config_template'],tpl,v,specs,bridges,external,storage,image_path)
            run(['pvesh','set',f'/pools/{pool}','--vms',f'+{vmid}'])
            manifest['vms'][-1]['created']=True
            manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
        run(['pveum','aclmod',f'/pool/{pool}','--user',user,'--role',role,'--propagate','1'])
        manifest['status']='complete'
        manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
        print(f'\nГотово: стенд {sid} создан. Пул: {pool}; пользователь: {user}; ВМ: {len(vmblocks)}.')
        print('Внутренние мосты сохраняются в конфигурации:',netfile)
        return {'sid':sid,'user':user,'password':generated_password,'vms':len(vmblocks),'status':'complete'}
    except Exception as e:
        manifest['status']='partial/error'; manifest['last_error']=str(e)
        manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
        print(f'\nОШИБКА при создании {sid}: {e}',file=sys.stderr)
        print(f'Частичный реестр сохранён: {manifest_path}. Ничего автоматически не удалялось.',file=sys.stderr)
        raise

def remove_stand():
    manifests=[]
    for f in sorted(STANDS.glob('*/manifest.json')) if STANDS.exists() else []:
        try: manifests.append((f,load_manifest(f)))
        except Exception: pass
    if not manifests: print('Нет стендов в реестре.'); return
    for i,(_,m) in enumerate(manifests,1): print(f'{i}. {m.get("sid")} — модуль {m.get("module")}, статус {m.get("status")}, ВМ {len(m.get("vms",[]))}')
    x=input('Номер стенда для удаления (Enter — отмена): ').strip()
    if not x:return
    if not x.isdigit() or not 1<=int(x)<=len(manifests): raise Failure('Некорректный номер.')
    path,m=manifests[int(x)-1]
    sid=m['sid']
    print(f'Будет удалён только стенд {sid}, его ВМ/диски, пул, созданный скриптом пользователь и мосты из его манифеста.')
    print('Внешний мост не удаляется. Ресурсы вне манифеста не трогаются.')
    if not yesno(f'Подтверждаешь полное удаление {sid}?'): return
    errors=[]
    # Delete only recorded VMIDs; never search and delete unregistered VMs.
    for vm in reversed(m.get('vms',[])):
        vmid=str(vm.get('vmid',''))
        if not vmid.isdigit(): continue
        if subprocess.run(['qm','status',vmid],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:
            r=run(['qm','destroy',vmid,'--purge','1','--destroy-unreferenced-disks','1'],check=False)
            if r.returncode: errors.append(f'VMID {vmid}: {(r.stderr or r.stdout).strip()}')
    pool=m.get('pool','')
    if pool:
        # Remove ACL first; only remove this pool after its VMs are gone.
        user=m.get('user','')
        if user:
            run(['pveum','aclmod',f'/pool/{pool}','--user',user,'--role',m.get('role','Competitor_DE'),'--delete','1'],check=False)
        r=run(['pvesh','delete',f'/pools/{pool}'],check=False)
        if r.returncode: errors.append(f'pool {pool}: {(r.stderr or r.stdout).strip()}')
    # Remove a user only if the script created it and it has no remaining ACLs.
    user=m.get('user','')
    if user and m.get('user_created'):
        # If ACL inspection fails, preserve the account for safety.
        acl=run(['pveum','acl','list','--output-format','json'],check=False)
        if acl.returncode==0:
            try:
                entries=json.loads(acl.stdout)
                remains=any(e.get('ugid')==user or e.get('user')==user for e in entries)
                if not remains: run(['pveum','user','delete',user],check=False)
                else: print(f'Пользователь {user} сохранён: у него ещё есть ACL.')
            except Exception: print(f'Не удалось проверить ACL — пользователь {user} сохранён для безопасности.')
        else: print(f'Не удалось проверить ACL — пользователь {user} сохранён для безопасности.')
    # Remove only recorded bridges, and only if no VM currently references them.
    bridges=m.get('bridges',[])
    blocked_bridges=set()
    for b in bridges:
        cfg=run(['grep','-R','-l',f'bridge={b}', '/etc/pve/qemu-server'],check=False)
        if cfg.returncode==0 and cfg.stdout.strip():
            errors.append(f'мост {b} всё ещё используется VM-конфигурацией; оставлен')
            blocked_bridges.add(b)
    netfile=Path(m.get('network_file','')) if m.get('network_file') else None
    # Bring down only this stand's bridges, then remove its persistent config.
    # Never run ifreload -a during cleanup: it can reconfigure unrelated interfaces.
    removable_bridges=[b for b in bridges if b not in blocked_bridges]
    if netfile and str(netfile).startswith(str(NETDIR)) and netfile.exists():
        try:
            # If any bridge is still referenced by a VM, retain the network file so it remains persistent.
            if not blocked_bridges:
                for b in removable_bridges:
                    if bridge_exists(b) and shutil.which('ifdown'):
                        run(['ifdown',b],check=False)
                netfile.unlink()
        except Exception as e: errors.append(f'не удалось удалить сетевой файл: {e}')
    for b in removable_bridges:
        # Never touch an external bridge and only remove names in the stand manifest.
        if b == m.get('external_bridge') or not re.fullmatch(r'd27[ab]\d{2}n\d{2}',b): continue
        if bridge_exists(b):
            # Ensure no interfaces are attached besides the bridge itself.
            ports=Path(f'/sys/class/net/{b}/brif')
            if ports.exists() and any(ports.iterdir()):
                errors.append(f'мост {b} имеет подключённые интерфейсы; не удалён')
                continue
            run(['ip','link','delete',b],check=False)
    if errors:
        m['status']='delete_partial'; m['delete_errors']=errors
        path.write_text(json.dumps(m,ensure_ascii=False,indent=2))
        print('Удаление завершено не полностью:')
        for e in errors: print(' -',e)
        print('Манифест оставлен для восстановления:',path)
    else:
        try: path.unlink()
        except OSError: pass
        try: path.parent.rmdir()
        except OSError: pass
        print(f'Стенд {sid} удалён. Внешняя сеть и остальные стенды сохранены.')

def validate_conf(templates,mods):
    issues=[]
    for n in (1,2):
        for k,v in mods[n].items():
            if not re.fullmatch(r'vm_\d+',k): continue
            name=v.get('name',k); t=v.get('config_template')
            if t not in templates: issues.append(f'Модуль {n}, {name}: шаблон {t!r} не найден.'); continue
            for key in ('memory','cores'):
                val=v.get(key,templates[t].get(key,'1'))
                if not str(val).isdigit() or int(val)<1: issues.append(f'Модуль {n}, {name}: некорректный {key}={val!r}.')
            try: get_net_specs(templates[t],v)
            except Exception as e: issues.append(f'Модуль {n}, {name}: {e}')
            img=v.get('boot_disk_0',templates[t].get('boot_disk_0',''))
            if not img: issues.append(f'Модуль {n}, {name}: не задан boot_disk_0.')
            elif not re.match(r'^https?://',img) and not Path(img).is_file(): issues.append(f'Модуль {n}, {name}: локальный образ не найден: {img}')
    return issues

def main():
    need_root()
    print('=== DEMO-2027 | менеджер стендов Proxmox VE ===')
    # conf.txt остаётся на GitHub. Загружаем его во временный файл только
    # на время работы процесса и удаляем при выходе; локальная копия не нужна.
    try:
        req=urllib.request.Request(CONF_URL,headers={'User-Agent':'DEMO-2027/1.0'})
        with urllib.request.urlopen(req,timeout=25) as response:
            payload=response.read()
    except Exception as e:
        raise Failure(f'Не удалось загрузить conf.txt с GitHub: {e}\nURL: {CONF_URL}')
    if not payload.strip(): raise Failure('GitHub вернул пустой conf.txt.')
    fd, temp_name = tempfile.mkstemp(prefix='demo-2027-conf-', suffix='.txt')
    os.close(fd)
    conf_path=Path(temp_name)
    conf_path.write_bytes(payload)
    atexit.register(lambda: conf_path.unlink(missing_ok=True))
    print(f'Конфигурация загружена с GitHub: {CONF_URL}')
    _,templates,mods=read_conf(conf_path)
    while True:
        print('\n1. Создать стенды\n2. Список стендов\n3. Выход\n4. Удалить стенд\n5. Проверить conf.txt')
        choice=input('Выбор: ').strip()
        if choice=='3': return
        try:
            if choice=='1':
                mod=input('Модуль (1 или 2): ').strip()
                if mod not in ('1','2'): print('Выбери 1 или 2.'); continue
                module=int(mod)
                amount=input('Количество стендов (1–99): ').strip()
                if not amount.isdigit() or not 1<=int(amount)<=99: print('Количество должно быть от 1 до 99.'); continue
                count=int(amount)
                external=input('Имя существующего внешнего моста (например vmbr0): ').strip()
                if not re.fullmatch(r'[A-Za-z0-9_.-]{1,15}',external): print('Некорректное имя моста.'); continue
                if not bridge_exists(external): print(f'Мост {external} сейчас не найден. Убедись, что это существующий внешний мост.'); continue
                storage=get_storage()
                issues=validate_conf(templates,mods)
                if issues:
                    print('\nОшибки/предупреждения конфигурации:')
                    for issue in issues: print(' -',issue)
                    if not yesno('Продолжить несмотря на эти проблемы?',False): continue
                start=input('Номер первого стенда (1–99): ').strip()
                if not start.isdigit() or not 1<=int(start)<=99 or int(start)+count-1>99: print('Диапазон номеров должен укладываться в 1–99.'); continue
                if not yesno(f'Создать {count} стенд(ов) модуля {module}, внешний мост {external}, storage {storage}?',False): continue
                credentials=[]
                for num in range(int(start),int(start)+count):
                    try:
                        result=create_stand(module,num,external,storage,templates,mods)
                        if result and result.get('password'):
                            credentials.append((result['sid'],result['user'],result['password']))
                    except Exception as e:
                        print(f'Стенд {num} не завершён: {e}')
                        if not yesno('Продолжить создание следующих стендов?',False): break
                if credentials:
                    print('\n=== СОХРАНИ ЭТИ УЧЁТНЫЕ ДАННЫЕ СЕЙЧАС ===')
                    print('Пароли показаны только для новых пользователей и не записываются в манифест.')
                    for sid,user,password in credentials:
                        print(f'{sid} | {user} | {password}')
            elif choice=='2': list_stands()
            elif choice=='4': remove_stand()
            elif choice=='5':
                issues=validate_conf(templates,mods)
                if not issues: print('Базовая проверка пройдена: шаблоны, сети и пути локальных образов выглядят корректно.')
                else:
                    print(f'Найдено замечаний: {len(issues)}')
                    for issue in issues: print(' -',issue)
                print('Примечание: URL-образы проверяются фактической загрузкой при создании стенда.')
            else: print('Неизвестный пункт меню.')
        except (Failure, OSError, ValueError, json.JSONDecodeError) as e:
            print(f'ОШИБКА: {e}',file=sys.stderr)
        except KeyboardInterrupt:
            print('\nПрервано пользователем. Если создание уже началось, манифест сохранён.')

try:
    main()
except Failure as e:
    print(f'ОШИБКА: {e}',file=sys.stderr); sys.exit(1)
except KeyboardInterrupt:
    print('\nОстановлено пользователем.'); sys.exit(130)
PY
