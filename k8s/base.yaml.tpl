apiVersion: v1
kind: Namespace
metadata:
  name: __NS__
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wif-sa
  namespace: __NS__
  annotations:
    azure.workload.identity/client-id: __CLIENT_ID__
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wif-other-sa
  namespace: __NS__
  annotations:
    azure.workload.identity/client-id: __CLIENT_ID__
