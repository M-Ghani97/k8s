#!/bin/bash
# set -euo pipefail
deploy_k3s () {
status=0
count=0
timeout=180
curl -sfL https://get.k3s.io | sh -s - --kubelet-arg="cloud-provider=external" --kubelet-arg="provider-id=openstack:///ea7053e0-fbc6-4ba2-9ff9-98b12bccdcb0"
while [ $status != '1' ]
  do
    if [ $count -eq $timeout ]
    then
      echo "Timeout, Cluster is not Ready State"
      exit 1
    fi
    status=`sudo kubectl get po -n kube-system | grep -i -v "Running\|Completed" | wc -l`
    count=$(( $count + 1 ))
    echo "[$count] Cluster Not Ready. Retrying ..."
    sleep 5s;
done
sudo chmod +r /etc/rancher/k3s/k3s.yaml
}

deploy_dashboard () {
GITHUB_URL=https://github.com/kubernetes/dashboard/releases
VERSION_KUBE_DASHBOARD=$(curl -w '%{url_effective}' -I -L -s -S ${GITHUB_URL}/latest -o /dev/null | sed -e 's|.*/||')
sudo k3s kubectl create -f https://raw.githubusercontent.com/kubernetes/dashboard/${VERSION_KUBE_DASHBOARD}/aio/deploy/recommended.yaml
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
EOF
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF
kubectl --namespace kubernetes-dashboard patch svc kubernetes-dashboard -p '{"spec": {"type": "NodePort"}}'
cat <<EOF > nodeport_dashboard_patch.yaml
spec:
  ports:
  - nodePort: 32000
    port: 443
    protocol: TCP
    targetPort: 8443
EOF
kubectl -n kubernetes-dashboard patch svc kubernetes-dashboard --patch "$(cat nodeport_dashboard_patch.yaml)"
}

deploy_cloud_manager () {
cat <<EOF > cloud.conf
[Global]
region=RegionOne
username=admin
password=ZpYUUjHuFmXXxOrb25XKiOplyf9KiQolPqjxZPmp
auth-url=http://172.0.10.1:5000/v3
tenant-id=56c2402be0d44e2fbcd6fb8b91c4280f
domain-id=default
EOF

cat  <<EOF > openstack-cloud-controller-manager-patch.yml
spec:
  template:
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: "true"
      containers:
        - name: openstack-cloud-controller-manager
          args:
            - /bin/openstack-cloud-controller-manager
            - --v=1
            - --cluster-name=\$(CLUSTER_NAME)
            - --cloud-config=\$(CLOUD_CONFIG)
            - --cloud-provider=openstack
            - --use-service-account-credentials=true
            - --bind-address=127.0.0.1
            - --secure-port=10255
EOF

kubectl create secret -n kube-system --dry-run=client generic cloud-config --from-file=cloud.conf -o yaml | kubectl apply -f -
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/controller-manager/cloud-controller-manager-roles.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/controller-manager/cloud-controller-manager-role-bindings.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/controller-manager/openstack-cloud-controller-manager-ds.yaml
kubectl -n kube-system patch daemonset.apps/openstack-cloud-controller-manager --patch "$(cat openstack-cloud-controller-manager-patch.yml)"
}

integrate_cinder_csi () {
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/cinder-csi-plugin/cinder-csi-controllerplugin-rbac.yaml   
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/cinder-csi-plugin/cinder-csi-controllerplugin.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/cinder-csi-plugin/cinder-csi-nodeplugin-rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/cinder-csi-plugin/cinder-csi-nodeplugin.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/cloud-provider-openstack/master/manifests/cinder-csi-plugin/csi-cinder-driver.yaml
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: csi-sc-cinder
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: cinder.csi.openstack.org
parameters:
  availability: nova
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF
}

check_cinder_csi () {
kubectl apply -f - <<EOF
--- 
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-volume
  namespace: default
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: csi-sc-cinder
  resources:
    requests:
      storage: 1Gi
--- 
apiVersion: v1
kind: Pod
metadata: 
  labels: 
    name: webserver
  name: nginx-webserver
spec: 
  containers: 
    - image: nginx
      name: webserver
      ports: 
        - containerPort: 80
          name: http
      volumeMounts: 
        - mountPath: /usr/local/nginx/html
          name: app-data
  volumes: 
    - name: app-data
      persistentVolumeClaim: 
        claimName: test-volume
EOF
}

deploy_k3s
deploy_cloud_manager
integrate_cinder_csi
check_cinder_csi
deploy_dashboard
