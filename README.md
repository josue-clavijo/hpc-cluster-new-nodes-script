# hpc-cluster-new-nodes-script

Script de configuracion para nodos de computo nuevos en un cluster Beowulf
con interconexion **InfiniBand** (tarjetas Mellanox ConnectX, driver `mlx5`),
pensado para **Linux Mint Cinnamon** (base Ubuntu).

## Que hace

`configure-new-node.sh` deja un nodo nuevo listo para integrarse al cluster:

- Usuario/grupo estandar (`ryzen`/`ryzen` por defecto) con **autologin** en LightDM.
- Ajustes de **Cinnamon** para que nunca se suspenda, bloquee ni active
  salvapantallas/DPMS. La interfaz grafica en si **nunca se desactiva**
  (se garantiza `graphical.target` + LightDM habilitados): queda disponible
  para monitorear el nodo localmente mientras trabaja el cluster.
- Desactivacion de suspension/hibernacion a nivel de `systemd`/`logind` y
  del autosuspend de USB.
- **Gobernador de CPU en `performance`** de forma persistente y, de forma
  opcional, parametros de kernel (`processor.max_cstate=1 idle=nomwait`)
  como mitigacion conocida para los congelamientos por estados C profundos
  en plataformas **AMD Ryzen/Threadripper** (1950X, 2990WX). Tambien
  opcional: `pcie_acs_override=downstream,multifunction`, el workaround
  documentado por la comunidad para el trafico peer-to-peer (InfiniBand/GPU)
  en Threadripper. Instala `numactl`/`hwloc-nox` y muestra la topologia NUMA
  real (relevante en el 2990WX, donde solo 2 de sus 4 dies tienen memoria
  conectada directamente).
- **Limites de memoria** (`memlock`, `nofile`) necesarios para RDMA, tanto
  vía PAM como vía `systemd` (incluyendo el servicio SSH).
- Instalacion de la pila **RDMA/InfiniBand** (`rdma-core`, `ibverbs-utils`,
  `infiniband-diags`, `perftest`, etc.) y carga de los modulos `mlx5_core`/
  `mlx5_ib`/`ib_cm`/`ib_ucm`/etc. Si no se detecta fisicamente la tarjeta
  Mellanox, el script **se detiene y espera** que el usuario decida:
  reintentar, continuar sin InfiniBand o abortar.
- Busqueda opcional, en la carpeta de descargas del usuario, de tarballs de
  **UCX, libfabric, LibXC y OpenMPI** ya descargados para compilarlos e
  instalarlos manualmente (suelen ser mas recientes/estables para RDMA que
  los paquetes de Mint/Ubuntu); si no se encuentran o el usuario no lo pide,
  se usan los paquetes del repositorio. Todo se instala en **el mismo
  prefijo** (configurable, por defecto `/usr/local`), que debe coincidir con
  la ruta que ya usan los demas nodos del cluster para evitar conflictos.
- Configuracion de la interfaz **IPoIB** con IP estatica en modo "connected"
  (MTU 65520) y mascara configurable (CIDR, debe coincidir con la de los
  demas nodos). La interfaz se detecta por `sysfs`
  (`/sys/class/infiniband/*/device/net/`), no adivinando el nombre: funciona
  igual si se llama `ib0` o algo como `ibp65s0` (nombres predecibles de
  systemd/udev por bus/slot PCI).
- Actualizacion de `/etc/hosts`, generacion de **llaves SSH** y copia hacia
  el nodo `master`.
- Cliente **NFS** y montaje del recurso compartido (por defecto
  `/home/<usuario>/cluster`, la misma ruta en el maestro y en cada nodo),
  con arranque automatico via `rpcbind`/`remote-fs.target`, verificacion
  previa con `showmount -e` (confirma que el maestro realmente esta
  exportando esa ruta antes de intentar montar, en vez de fallar a ciegas),
  la opcion de registrar automaticamente el nodo en `/etc/exports` del
  maestro via SSH (con `sync` por defecto o `async` si se prefiere
  velocidad sobre seguridad ante una caida del maestro), y la opcion de
  montar por **NFS/RDMA** (puerto 20049, con `xprtrdma` en el cliente y
  `svcrdma` + `echo rdma 20049 > /proc/fs/nfsd/portlist` **solo en el
  maestro**, que es el unico que corre `nfsd`) en vez de TCP/IPoIB normal.
- **Directorio compartido del cluster** (dentro del propio NFS, en
  `cluster-conf/`): fusiona `/etc/hosts` y `authorized_keys` de todos los
  nodos que han pasado por el script, incluyendo el auto-registro de este
  mismo nodo (util para pruebas de redundancia) y, la primera vez, la
  opcion de registrar a mano los nodos que ya existian antes.
- Toolchain de compilacion y **MPI** (`build-essential`, `gfortran`,
  OpenMPI + UCX) configurado para usar InfiniBand entre nodos; OpenMP ya
  viene incluido en `gcc`/`gfortran` (`-fopenmp`).
- Variables de entorno (rutas del stack HPC —incluyendo el subdirectorio
  `ucx/` donde UCX carga sus modulos de transporte—, preferencia UCX de
  OpenMPI, afinidad de nucleos para Threadripper, `MKL_CBWR=AUTO`,
  `MKL_ENABLE_INSTRUCTIONS=AVX2`, `MKL_THREADING_LAYER=GNU` (evita que MKL
  cargue su propio runtime OpenMP junto al de gcc/gfortran) y
  activacion automatica de Intel MKL/oneAPI si esta instalado) inyectadas
  al **principio** de `~/.bashrc` del usuario del cluster, antes del
  guardian que corta la ejecucion para shells no interactivas — asi
  tambien las ve `mpirun --host otro_nodo` cuando lanza procesos remotos
  via SSH (bash detecta que lo invoca sshd y lee `.bashrc` igual, pero
  corta justo en ese guardian si no se pone el contenido antes), no solo
  una terminal abierta. No se activan los componentes de MPI/compilador de
  Intel, para no chocar con OpenMPI/gcc, que es lo que usa este cluster.

Al terminar, el nodo queda listo para instalar sobre esta base las
bibliotecas de aplicacion (Intel MKL, Quantum ESPRESSO, etc.).

## Uso

```bash
sudo ./configure-new-node.sh              # configuracion interactiva
sudo ./configure-new-node.sh --rollback   # modo de rescate (ver abajo)
sudo ./configure-new-node.sh --help
```

El script es **interactivo**: pregunta el nombre del nodo, la IP InfiniBand
que le corresponde (`10.10.10.X`), los datos del nodo maestro y algunas
confirmaciones antes de aplicar cambios. Se puede volver a ejecutar sobre el
mismo nodo sin problema; los pasos son idempotentes.

Registra su actividad en `/var/log/hpc-node-setup.log` y guarda los
parametros usados en `/etc/hpc-cluster/node.conf`.

## Modo de rescate (`--rollback`)

Cada etapa deja registrado en `/etc/hpc-cluster/manifest.log` cada archivo
que crea o modifica (con copia de respaldo `.hpc-orig` para lo que ya
existia). Si algo sale mal y no hay forma de recuperar el estado anterior,
`sudo ./configure-new-node.sh --rollback`:

1. Deshace esos cambios en orden inverso (restaura los `.hpc-orig`, borra
   los archivos/unidades systemd que el script creo, desenmascara
   suspension/hibernacion, restaura el hostname y el target de arranque por
   defecto, borra la conexion de red IPoIB creada).
2. Aplica ademas una **red de seguridad fija**, independiente del
   manifiesto (por si esta incompleto o no existe): deja SSH habilitado,
   desenmascara suspension/hibernacion, y si hay GRUB, lo regenera desde
   `/etc/default/grub` ya restaurado.
3. Quita el bloque de variables de entorno de `~/.bashrc`.

El objetivo es que, pase lo que pase, el nodo quede **arrancable y
minimamente usable** (sin InfiniBand ni los ajustes de estabilidad) para
poder reintentar la configuracion desde cero.

**A propósito nunca toca:** el usuario/grupo del cluster ni sus archivos
(home, llaves SSH), los paquetes instalados via `apt`, ni el directorio
compartido del cluster en el NFS (`cluster-conf/`) — otros nodos pueden
depender de el.

## Verificar integridad de `~/.bashrc` (`reference/`)

`reference/expected-bashrc-block.sh` es el bloque exacto que
`stage_bashrc_environment` inserta en `~/.bashrc` (extraido programaticamente
del propio script, no transcrito a mano), con el prefijo por defecto
`/usr/local`. Sirve como patron de referencia para detectar ediciones
manuales, corrupcion, o codigo inyectado despues de que el script termino.

```bash
sudo ./reference/check-bashrc-integrity.sh [usuario]
```

Extrae el bloque marcado del `.bashrc` real, ajusta el patron al prefijo
que de verdad se uso en ese nodo (leido de `/etc/hpc-cluster/node.conf`), y
muestra un diff si no coincide exactamente. Sin argumento usa el
`CLUSTER_USER` guardado en `node.conf` (o `ryzen` si no lo encuentra).
Salida: `0` = coincide, `1` = difiere (revisar el diff), `2` = no existe el
archivo o el bloque. Probado contra una corrida real del script: caso
identico (OK), bloque con una linea inyectada a mano (la detecta y la
muestra en el diff), y bloque ausente por completo (lo reporta como tal).

## Auditar un nodo existente (`reference/audit-node-config.sh`)

Los nodos que ya estaban en el cluster antes de este script tienen su propia
configuracion manual y probablemente no coincidan exactamente con lo que deja
`configure-new-node.sh` en un nodo nuevo. En vez de "resetear" esos nodos de
una sola pasada (riesgoso si ya estan funcionando bien), `audit-node-config.sh`
permite comparar su configuracion real contra el estandar del nodo nuevo, de
solo lectura: **no instala nada, no edita ningun archivo, no reinicia ningun
servicio.**

```bash
sudo ./reference/audit-node-config.sh > reporte-nodo3.txt
```

Revisa usuario/grupo y autologin, estabilidad de Cinnamon (suspension,
bloqueo, DPMS), gobernador de CPU y parametros de GRUB, limites de memoria
para RDMA, la pila RDMA/InfiniBand y la interfaz IPoIB, `/etc/hosts`, SSH,
el montaje NFS y el directorio compartido `cluster-conf/`, el toolchain
MPI/OpenMP, y el bloque de variables de entorno en `~/.bashrc` (reutilizando
`check-bashrc-integrity.sh`). Cada linea queda marcada como `[OK]`, `[DIFF]`
(existe pero con otro valor/contenido), `[MISSING]` (no existe), `[WARN]`
(no se pudo verificar, o es una diferencia que puede ser normal segun el
hardware del nodo) o `[INFO]`. Al final imprime un resumen y la lista de
items `DIFF`/`MISSING`; el codigo de salida es `1` si hubo alguno, `0` si el
nodo coincide en todo.

Si el nodo nunca corrio este script, usa valores por defecto (`ryzen`/`ryzen`,
prefijo `/usr/local`, maestro `master`/`10.10.10.1`); se pueden ajustar con
`--user=`, `--group=`, `--prefix=`, `--master-host=`, `--master-ip=`.

El reporte generado (el `.txt` redirigido arriba) es el punto de partida para
decidir, nodo por nodo, que diferencias vale la pena armonizar y en que orden,
en vez de aplicar cambios a ciegas.

## Requisitos previos

- Linux Mint (o derivado de Ubuntu/Debian) con acceso a internet para
  instalar paquetes.
- La tarjeta InfiniBand Mellanox ya instalada fisicamente en el nodo.
- Conocer la IP InfiniBand que le corresponde al nuevo nodo y los datos del
  nodo `master` (hostname, IP InfiniBand, ruta NFS exportada).

## Validacion

Sin hardware InfiniBand real ni un maestro real, el script se corrio
completo (con `lspci`, `modprobe`, `apt-get`, `ssh*`, `mount`, etc.
simulados) para verificar la logica de las ramas: tarjeta ausente ->
pregunta interactiva -> continuar sin IB; NFS sin poder montar -> el
directorio compartido se omite en vez de fallar; llaves SSH generadas con
los permisos correctos. Esa simulacion encontro y corrigio dos bugs reales:
el directorio `~/.ssh` se creaba como root (700) antes de generar la llave
como el usuario del cluster, lo que hacia fallar `ssh-keygen` por permisos;
y si `ssh-keygen` fallaba, el script igual reportaba exito en vez de
marcar la etapa como fallida.

Una segunda ronda de revision (logica, redundancia, consistencia) encontro
y corrigio: una variable muerta sin usar, la mascara CIDR de InfiniBand sin
validar, dos archivos de PAM modificados sin respaldo previo, y una doble
instalacion de UCX (repositorio + compilado) cuando solo UCX se compilaba
desde fuente pero OpenMPI no. Tambien se agrego el sistema de manifiesto +
`--rollback`, y se probo de punta a punta: se tomo una foto del estado del
sistema antes de correr el script, se corrio el script completo, se corrio
`--rollback`, y se comparo — `/etc/hosts`, `/etc/fstab` y los archivos de
PAM quedaron **bit a bit identicos** al estado original, los 12
archivos/unidades creados desaparecieron, y el usuario del cluster no se
toco. Tambien se probo `--rollback` sin manifiesto (cae a la red de
seguridad sola) y ejecutado dos veces seguidas (idempotente).

## Despues de ejecutar el script

1. Define la contrasena del usuario `ryzen` si es nuevo: `passwd ryzen`.
2. **Reinicia el nodo** para que tomen efecto el gobernador de CPU, los
   parametros de kernel y la interfaz IPoIB.
3. Verifica la conectividad InfiniBand: `ibstat`, `ping <ip_master>`,
   `ibping`.
4. Prueba MPI entre nodos: `mpirun --host <nodo>,<master> -np 2 hostname`.
5. Revisa en la BIOS del nodo `Global C-State Control` / `Core C6 State` en
   *Disabled* (y en el 2990WX, `NUMA nodes per socket` = 4/Die) como
   complemento a los ajustes de software, si persisten congelamientos.
6. Las variables de entorno ya quedan en `~/.bashrc`; no hace falta tocarlas
   a mano salvo que instales algo en una ruta distinta.
7. Si ya tenias otros nodos en el cluster, vuelve a correr este script (o
   al menos la etapa del directorio compartido) en ellos para que
   reconozcan por `/etc/hosts` y SSH a este nodo nuevo.
