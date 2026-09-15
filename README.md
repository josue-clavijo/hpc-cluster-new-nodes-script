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
- Cliente **NFS** y montaje del recurso compartido (por defecto `/cluster`),
  con arranque automatico via `rpcbind`/`remote-fs.target`, la opcion de
  registrar automaticamente el nodo en `/etc/exports` del maestro via SSH, y
  la opcion de montar por **NFS/RDMA** (puerto 20049, con `xprtrdma` en el
  cliente y `svcrdma` + `echo rdma 20049 > /proc/fs/nfsd/portlist` en el
  maestro) en vez de TCP/IPoIB normal.
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
sudo ./configure-new-node.sh
```

El script es **interactivo**: pregunta el nombre del nodo, la IP InfiniBand
que le corresponde (`10.10.10.X`), los datos del nodo maestro y algunas
confirmaciones antes de aplicar cambios. Se puede volver a ejecutar sobre el
mismo nodo sin problema; los pasos son idempotentes.

Registra su actividad en `/var/log/hpc-node-setup.log` y guarda los
parametros usados en `/etc/hpc-cluster/node.conf`.

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
