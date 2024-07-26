#!/bin/bash
# set -e 
# set -o pipefail
STARTTIME=$(date -u +%Y-%m-%dT%H:%M)
PIDFILE=/var/run/dssosreport.pid
NAMESPACE=default
IMAGE=alpine:3.15
# IMAGE=mcr.microsoft.com/dotnet/runtime-deps:6.0
SOSREPORT_ARGS="-a"
CP_COMMAND="cd /tmp && tar zvc dspcap"
DEL_COMMAND="rm -rf /tmp/dspcap"


# create the daemonset 
createds() {
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dssosreport
  namespace: $NAMESPACE
spec:
  selector:
    matchLabels:
      app: dssosreport
  template:
    metadata:
      labels:
        app: dssosreport
    spec:
      hostPID: true
      hostNetwork: true
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/master
      containers:
      - name: sosreport
        command:
        - nsenter
        - --mount=/proc/1/ns/mnt
        - --
        - bash
        - -xc
        - |
          echo "start to generate sosreport"
          sos report --batch $SOSREPORT_ARGS &
          echo \$! >$PIDFILE
          wait
          rm $PIDFILE
          echo "sleeping forever \$(NODE_NAME)"
          sleep infinity
        image: $IMAGE
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        resources:
          requests:
            cpu: 50m
            memory: 50M
        securityContext:
          privileged: true
EOF
  
  sleep 2
  RET=$(kubectl rollout status daemonset/dssosreport -n $NAMESPACE )
  echo "Generating sosreport started. : $RET"
}

# progress bar
checkstatus() {
  bar="#\r"
  pods=$(kubectl get pods -l app=dssosreport -o name)
  for po in $(echo ${pods}); do
    run=true
    while $run ; do
      kubectl logs $po --tail=2 | grep "sleep infinity"
      if [ $? -eq 0 ]; then run=false; fi
      bar="${bar}#"
      sleep 3
      echo -ne $bar
    done
  done
  echo "Generating sosreport finished. : $RET"
}

# getting the sosreport files
files() {
  for pod in $(kubectl get po -l app=dssosreport -o jsonpath='{.items[*].metadata.name}' -n default); do
    _filename=$(kubectl logs $pod | grep -E "sosreport-(.*).tar.xz" | awk -F '/' '{print $3}')
    echo " - downloading sosreport for $pod : $_filename"
    kubectl cp $pod:$_filename /tmp/$_filename
  done
  echo "Generated sosreports copied."
}

# delete the daemonset 
deleteds() {
  pods=$(kubectl get pods -l app=dssosreport -o name)
  for po in $(echo ${pods}); do
    echo "  deleting sosreport for $po"
    kubectl exec -n $NAMESPACE "$po" -- bash -c "$DEL_COMMAND"
  done

  kubectl delete daemonset/dssosreport -n $NAMESPACE
  echo "Generated sosreport deleted."
}

createds
checkstatus
files
deleteds
