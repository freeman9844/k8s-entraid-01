apiVersion: batch/v1
kind: Job
metadata:
  name: __NAME__
  namespace: __NS__
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: __SA__
      restartPolicy: Never
      containers:
        - name: demo
          image: python:3.12-slim
          command: ["sh", "-c", "pip install -q --disable-pip-version-check azure-identity openai && python /app/demo.py"]
          env:
            - name: FOUNDRY_ENDPOINT
              value: "__ENDPOINT__"
            - name: FOUNDRY_DEPLOYMENT
              value: "__DEPLOYMENT__"
            - name: WIF_RETRIES
              value: "__RETRIES__"
          volumeMounts:
            - name: app
              mountPath: /app
      volumes:
        - name: app
          configMap:
            name: wif-demo-app
