# hpc-cluster-new-nodes-script

Script de configuracion para nodos de computo nuevos en un cluster Beowulf
con interconexion **InfiniBand** (tarjetas Mellanox ConnectX, driver `mlx5`),
pensado para **Linux Mint Cinnamon** (base Ubuntu).

## Que hace

`configure-new-node.sh` deja un nodo nuevo listo para integrarse al cluster:

- Usuario/grupo estandar (`ryzen`/`ryzen` por defecto) con **autologin** en LightDM.
- Ajustes de **Cinnamon** para que nunca se suspenda, bloquee ni active
  salvapantallas/DPMS.
- Desactivacion de suspension/hibernacion a nivel de `systemd`/`logind` y
  del autosuspend de USB.
- **Gobernador de CPU en `performance`** de forma persistente y, de forma
  opcional, parametros de kernel (`processor.max_cstate=1 idle=nomwait`)
  como mitigacion conocida para los congelamientos por estados C profundos
  en plataformas **AMD Ryzen**.
- **Limites de memoria** (`memlock`, `nofile`) necesarios para RDMA, tanto
  vía PAM como vía `systemd` (incluyendo el servicio SSH).
- Instalacion de la pila **RDMA/InfiniBand** (`rdma-core`, `ibverbs-utils`,
  `infiniband-diags`, `perftest`, etc.) y carga de los modulos `mlx5_core`/
  `mlx5_ib`.
- Configuracion de la interfaz **IPoIB** (`ib0`) con IP estatica en modo
  "connected" (MTU 65520).
- Actualizacion de `/etc/hosts`, generacion de **llaves SSH** y copia hacia
  el nodo `master`.
- Cliente **NFS** y montaje del recurso compartido (por defecto `/cluster`),
  con la opcion de registrar automaticamente el nodo en `/etc/exports` del
  maestro via SSH.
- Toolchain de compilacion y **MPI** (`build-essential`, `gfortran`,
  OpenMPI + UCX) configurado para usar InfiniBand entre nodos; OpenMP ya
  viene incluido en `gcc`/`gfortran` (`-fopenmp`).

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

## Despues de ejecutar el script

1. Define la contrasena del usuario `ryzen` si es nuevo: `passwd ryzen`.
2. **Reinicia el nodo** para que tomen efecto el gobernador de CPU, los
   parametros de kernel y la interfaz IPoIB.
3. Verifica la conectividad InfiniBand: `ibstat`, `ping <ip_master>`,
   `ibping`.
4. Prueba MPI entre nodos: `mpirun --host <nodo>,<master> -np 2 hostname`.
5. Revisa en la BIOS del nodo `Global C-State Control` / `Core C6 State` en
   *Disabled* como complemento a los ajustes de software, si persisten
   congelamientos.
