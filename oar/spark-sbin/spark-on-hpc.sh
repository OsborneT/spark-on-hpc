#!/bin/bash

#stop as soon as first command fails
set -e

#SPARK_JOB_DIR and SPARK_HOME variables must be set
if [ -z "$SPARK_JOB_DIR" -o -z "$SPARK_HOME" ]; then
   echo "spark-on-hpc.sh requires environment variables SPARK_HOME and SPARK_JOB_DIR" 2>&1
   exit 1
fi

#SPARK_JOB_DIR must point to a directory
if [ ! -d "$SPARK_JOB_DIR" ]; then
   echo "Cannot find SPARK_JOB_DIR" 2>&1 
   exit 1
fi

#concretize if symlinks and make sure each points to an existing file/folder
SPARK_JOB_DIR=$(readlink -e "$SPARK_JOB_DIR")
SPARK_HOME=$(readlink -e "$SPARK_HOME")

#init variables that point to conf folder and spark configuration files (spark-default.conf and spark-env.sh)
SPARK_CONF_DIR=$SPARK_JOB_DIR/conf
SPARK_CONF=$SPARK_CONF_DIR/spark-defaults.conf
SPARK_ENV=$SPARK_CONF_DIR/spark-env.sh

#init hostnames into SLAVES variable
if [ -f "$SPARK_CONF_DIR/slaves" ]; then
   SLAVES=`cat $SPARK_CONF_DIR/slaves`
fi

#consider the input command passed as the first argument (start, stop, config and vars)
# start - checks if  config was executed; sources spark-env.sh; if not created it created 2 random ports on the master; starts master and master-web-interface; starts slaves
# stop - stops slaves; stops master; overwrites ports
# config - reads config (must not exist); finds resources assigned to submission (nodes, cpus, cores, memory); assigns master to first node and slaves to the rest
case "$1" in 
   start)

      #config must run first to set up $SPARK_ENV
      if [ ! -f "$SPARK_ENV" ]; then
         echo "No $SPARK_ENV found. Run spark-on-hpc.sh config first." >&2
         exit 1
      fi

      #source $SPARK_ENV
      . $SPARK_ENV
      echo "Use spark config $SPARK_ENV"

      #generate 2 random ports on the master
      if [ -z "$SPARK_MASTER_PORT" ] || [ "$SPARK_MASTER_PORT" = "RANDOM" ]; then
         RANDOM_PORT_CMD="python -c 'import socket; s1=socket.socket(); s1.bind((\"\", 0)); s2=socket.socket(); s2.bind((\"\",0)); print(\"%d %d\" % (s1.getsockname()[1],s2.getsockname()[1])); s1.close(); s2.close()'"
         RANDOM_PORTS=`oarsh $SPARK_MASTER_IP $RANDOM_PORT_CMD`

         read SPARK_MASTER_PORT SPARK_MASTER_WEBUI_PORT <<< $(echo $RANDOM_PORTS)
         if [ -z "$SPARK_MASTER_PORT" ]; then
            echo "Cannot find a random port" >&2
            exit 1
         fi
	 
	 #write the ports in the SPARK_ENV file (not sure why)
         sed -i -e "s/^SPARK_MASTER_PORT=.*$/SPARK_MASTER_PORT=$SPARK_MASTER_PORT/" -e "s/^SPARK_MASTER_WEBUI_PORT=.*$/SPARK_MASTER_WEBUI_PORT=$SPARK_MASTER_WEBUI_PORT/" $SPARK_ENV
      fi

      echo "Master URL =  spark://$SPARK_MASTER_IP:$SPARK_MASTER_PORT"
      echo "Web UI URL =  http://$SPARK_MASTER_IP:$SPARK_MASTER_WEBUI_PORT"
      echo 

      # run spark-daemon-on-hpc.sh script on the master 
      oarsh $SPARK_MASTER_IP "SPARK_PREFIX=$SPARK_PREFIX ${SPARK_HOME}/sbin/spark-daemon-on-hpc.sh --config $SPARK_CONF_DIR start org.apache.spark.deploy.master.Master 1 --ip $SPARK_MASTER_IP --port $SPARK_MASTER_PORT --webui-port $SPARK_MASTER_WEBUI_PORT" 2>&1 | sed "s/^/$SPARK_MASTER_IP: /"

      # run spark-daemon-on-hpc.sh script on all the slaves
      SLAVE_NUM=1
      for slave in $SLAVES; do
         oarsh $slave "SPARK_PREFIX=$SPARK_PREFIX ${SPARK_HOME}/sbin/spark-daemon-on-hpc.sh --config $SPARK_CONF_DIR start org.apache.spark.deploy.worker.Worker $SLAVE_NUM spark://$SPARK_MASTER_IP:$SPARK_MASTER_PORT" 2>&1 | sed "s/^/$slave: /" &
         (( SLAVE_NUM++ ))   
      done

      wait

      ;;

   stop)
      if [ ! -f "$SPARK_ENV" ]; then
         echo "No $SPARK_ENV found. Run spark-on-hpc.sh config first." >&2
         exit 1
      fi

      #source $SPARK_ENV
      . $SPARK_ENV
      echo "Use spark config $SPARK_ENV"

      # stop all the slaves
      SLAVE_NUM=1
      for slave in $SLAVES; do
         oarsh $slave "SPARK_PREFIX=$SPARK_PREFIX ${SPARK_HOME}/sbin/spark-daemon-on-hpc.sh --config $SPARK_CONF_DIR stop org.apache.spark.deploy.worker.Worker $SLAVE_NUM" 2>&1 | sed "s/^/$slave: /" &
         (( SLAVE_NUM++ ))   
      done

      # stop the master
      oarsh $SPARK_MASTER_IP "SPARK_PREFIX=$SPARK_PREFIX ${SPARK_HOME}/sbin/spark-daemon-on-hpc.sh --config $SPARK_CONF_DIR stop org.apache.spark.deploy.master.Master 1" 2>&1 | sed "s/^/$SPARK_MASTER_IP: /" &

      # overwrite the 2 master ports in the local config (not sure why...)
      sed -i -e "s/^SPARK_MASTER_PORT=.*$/SPARK_MASTER_PORT=RANDOM/" -e "s/^SPARK_MASTER_WEBUI_PORT=.*$/SPARK_MASTER_WEBUI_PORT=RANDOM/" $SPARK_ENV

      wait
      ;;

   config)
      GEN_HEADER="#--------------Generated by spark-on-hpc.sh -----------------#"
      GEN_FOOTER="#------------------------------------------------------------#"

      # there must not be any running cluster
      if [ -f "$SPARK_ENV" ] && (grep -q "$GEN_HEADER" "$SPARK_ENV"); then
         echo "Existing spark config in $SPARK_JOB_DIR/conf is found, make sure no spark cluster is running or remove the configuration first!!" >&2
         exit 1
      fi

      # check if deployed using OAR 
      [ -f "$OAR_NODEFILE" ] || { echo "No OAR_NODEFILE found, should run under oarsub" >&2 ; exit 1; }


      # check if resources are specified
      [ -f "$OAR_RESOURCE_PROPERTIES_FILE" ] || { echo "OAR_RESOURCE_PROPERTIES_FILE does not exist, no info on the available resources" >&2 ; exit 1; }
     
      nodes=($( cat $OAR_NODEFILE | uniq | sort ))
      nnodes=${#nodes[@]}
      last=$(( $nnodes - 1 ))

      cores=`oarprint host -P host,cpu,core -F " % | % | %" -C+  | cut -d "|" -f3 | grep -o "+" | wc -l`
      cores=$((cores+1))

      SPARK_WORKER_DIR=$SPARK_JOB_DIR/work
      SPARK_WORKER_CORES=$cores
      SPARK_LOG_DIR=$SPARK_JOB_DIR/logs
      SPARK_PID_DIR=$SPARK_LOG_DIR
      SPARK_SLAVES=$SPARK_CONF_DIR/slaves

      MAX_MEM=`ulimit -v`
      if [ "$MAX_MEM" = "unlimited" ] || [ -z "$MAX_MEM" ]; then
         echo "WARNING -l vmem not set, use spark memory 2gb by default" >&2
         SPARK_WORKER_MEMORY="2g"
      else 
         SPARK_WORKER_MEMORY="$((($MAX_MEM+1024-1)/1024))m"
      fi

      SPARK_MASTER_IP=${nodes[0]}

      mkdir -p $SPARK_CONF_DIR
      cat << EOF >> $SPARK_ENV
$GEN_HEADER
SPARK_MASTER_IP=$SPARK_MASTER_IP
SPARK_MASTER_PORT=RANDOM
SPARK_MASTER_WEBUI_PORT=RANDOM
SPARK_WORKER_DIR=$SPARK_WORKER_DIR
SPARK_WORKER_CORES=$SPARK_WORKER_CORES
SPARK_WORKER_MEMORY=$SPARK_WORKER_MEMORY
SPARK_LOG_DIR=$SPARK_LOG_DIR
SPARK_PID_DIR=$SPARK_PID_DIR
$GEN_FOOTER
EOF

      SECRET=`date | md5sum | head -c6`
      cat << EOF >> $SPARK_CONF
$GEN_HEADER
spark.eventLog.enabled           true
spark.eventLog.dir               file://$SPARK_LOG_DIR

spark.executor.memory		$SPARK_WORKER_MEMORY
spark.driver.memory		$SPARK_WORKER_MEMORY

spark.authenticate              true
spark.authenticate.secret       $SECRET
$GEN_FOOTER
EOF

      printf '%s\n' ${nodes[@]:1} > $SPARK_SLAVES
      ;;

   vars) 
      if [ ! -f "$SPARK_ENV" ] || ! (grep -q "$GEN_HEADER" "$SPARK_ENV"); then
         echo "$SPARK_ENV not found, run spark-on-hpc.sh config first" >&2
         exit 1
      fi
      # Promote to environment variables but doesn't work unless the calling script does this too.
      set -a   
      . $SPARK_ENV
      set +a
      export SPARK_CONF_DIR

      function clean_up {
         echo "Got KILL Signal"
         $SPARK_HOME/sbin/spark-on-hpc.sh stop
         exit 1
      }
      trap clean_up SIGTERM
      echo "Set SIGTERM Handler"
      ;;

   *)
      echo "Usage: spark-on-hpc.sh {config|start|stop}" >&2
      echo "       . ./spark-on-hpc.sh vars (notice the dot)" >&2
      exit 1
      ;;

esac

# Make sure to set this before exit the script normally (exit 0)
set +e
