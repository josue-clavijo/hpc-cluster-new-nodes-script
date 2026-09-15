# >>> hpc-cluster-new-nodes-script (bloque generado automaticamente; no borrar) >>>
# Rutas del stack HPC (UCX/OpenMPI/libfabric/LibXC). Este prefijo debe ser
# IGUAL en todos los nodos del cluster.
export HPC_PREFIX="/usr/local"
export PATH="${HPC_PREFIX}/bin:${PATH}"
# LIBRARY_PATH es lo que usa gcc/gfortran en tiempo de COMPILACION/enlace
# para encontrar -lucx, -lfabric, etc. sin necesitar -L explicito.
export LIBRARY_PATH="${HPC_PREFIX}/lib:${LIBRARY_PATH:-}"
# UCX carga sus modulos de transporte (verbs, shared memory, etc.) desde un
# subdirectorio "ucx/" propio, no solo desde el lib/ general; si no esta en
# el path puede perder silenciosamente el soporte de InfiniBand y caer a
# TCP. Se incluyen ambas rutas (la del stack compilado y la del paquete
# libucx0 de Ubuntu/Mint) para cubrir los dos casos.
export LD_LIBRARY_PATH="${HPC_PREFIX}/lib:${HPC_PREFIX}/lib/ucx:/usr/lib/ucx:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="${HPC_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# MPI sobre InfiniBand: preferir UCX (usa los verbs de Mellanox/mlx5) entre
# nodos y memoria compartida dentro de un mismo nodo.
export OMPI_MCA_pml=ucx
export OMPI_MCA_btl=self,vader

# Afinidad de nucleos para AMD Ryzen/Threadripper (1950X de 16 nucleos,
# 2990WX de 32 nucleos): atar cada proceso/hilo a nucleos concretos evita
# que el planificador los mueva entre CCX/dies con memoria remota, lo cual
# en el 2990WX en particular (solo 2 de sus 4 dies tienen memoria conectada
# directamente) puede ser bastante mas lento. Revisa la topologia real con
# 'numactl --hardware' o 'lstopo' antes de lanzar trabajos grandes.
export OMP_PROC_BIND=close
export OMP_PLACES=cores
export OMPI_MCA_hwloc_base_binding_policy=core

# Intel MKL / oneAPI: se activa solo si ya esta instalado (lo instalas tu
# mismo mas adelante junto con Quantum ESPRESSO). Se prueba primero la ruta
# especifica del componente MKL (mas liviana) y se cae al setvars.sh general
# solo si no existe; NUNCA se activan los componentes de MPI/compilador de
# Intel para no chocar con OpenMPI/gcc, que es lo que usa este cluster.
if [ -f /opt/intel/oneapi/mkl/latest/env/vars.sh ]; then
    source /opt/intel/oneapi/mkl/latest/env/vars.sh > /dev/null 2>&1
elif [ -f /opt/intel/oneapi/setvars.sh ]; then
    # Respaldo: activa todo oneAPI (incluye MPI/compiladores de Intel si
    # estan instalados). Si eso llega a chocar con OpenMPI/gcc en el PATH,
    # instala solo el componente MKL para que la rama de arriba lo detecte.
    source /opt/intel/oneapi/setvars.sh --force > /dev/null 2>&1
elif [ -f /opt/intel/mkl/bin/mklvars.sh ]; then
    source /opt/intel/mkl/bin/mklvars.sh intel64 > /dev/null 2>&1
fi

# MKL_CBWR (Conditional Bitwise Reproducibility, antes llamado "CNR"): fuerza
# a MKL a usar siempre la MISMA ruta de codigo en vez de la que el CPU
# detecte en cada corrida, para que dos ejecuciones (incluso en nodos
# distintos) den resultados numericamente identicos bit a bit. AUTO deja
# que MKL elija la ruta optima sin forzar reproducibilidad (equivalente a
# tenerlo desactivado); cambialo a un valor fijo (p.ej. AVX2) si necesitas
# que dos nodos den exactamente el mismo resultado en Quantum ESPRESSO.
export MKL_CBWR=AUTO

# Instrucciones vectoriales que MKL tiene PERMITIDO usar como maximo (nunca
# fuerza una ruta de codigo incorrecta: solo pone un techo). En el
# 1950X/2990WX (Zen1/Zen+, sin AVX-512) el techo real de hardware es AVX2.
# Es el reemplazo actual de MKL_DEBUG_CPU_TYPE, que Intel desactivo hace
# varios anios (hoy no tiene ningun efecto, por eso no se incluye aqui).
# Aun asi, en CPUs no-Intel el beneficio no esta garantizado: Intel no
# promete el despacho optimo fuera de sus propios procesadores.
export MKL_ENABLE_INSTRUCTIONS=AVX2

# Evita que MKL cargue su PROPIO runtime de OpenMP (libiomp5) por separado
# del que usan gcc/gfortran (libgomp, via -fopenmp). Tener dos runtimes de
# OpenMP activos a la vez en el mismo proceso es una causa real y conocida
# de sobre-suscripcion de nucleos y cuelgues en codigos hibridos MPI+OpenMP
# que llaman a MKL (como Quantum ESPRESSO). Como este cluster compila con
# gcc/gfortran (no con los compiladores de Intel), "GNU" es la opcion
# correcta aqui.
export MKL_THREADING_LAYER=GNU

# A PROPOSITO no se fija aqui un numero de hilos fijo para MKL
# (MKL_NUM_THREADS / MKL_DYNAMIC=FALSE): el valor correcto depende de
# cuantos procesos MPI por nodo uses en cada corrida (p.ej. un solo rango
# usando todos los nucleos vs. varios rangos con pocos hilos cada uno).
# Fijarlo aqui de forma global, igual para toda corrida, es exactamente el
# tipo de ajuste "demasiado especifico" que puede sobre-suscribir los
# nucleos y pisarse con el paralelismo de OpenMPI/OpenMP: ajusta
# OMP_NUM_THREADS (y MKL_NUM_THREADS si hace falta) en el script de cada
# trabajo especifico, no en este archivo. Por la misma razon tampoco se
# toca MKL_INTERFACE_LAYER (LP64/ILP64): debe coincidir exactamente con
# como se compilo/enlazo cada programa, no es algo que se pueda fijar de
# forma general para todo el sistema.
# <<< hpc-cluster-new-nodes-script <<<
