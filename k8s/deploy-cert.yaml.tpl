apiVersion: apps/v1
kind: Deployment
metadata:
  name: __NAME__
  namespace: __NS__
spec:
  replicas: 1
  selector:
    matchLabels:
      app: __NAME__
  template:
    metadata:
      labels:
        app: __NAME__
    spec:
      containers:
        - name: demo
          image: python:3.12-slim
          command: ["sh", "-c", "pip install -q --disable-pip-version-check azure-identity openai && python /app/demo_cert.py; sleep infinity"]
          env:
            - name: AZURE_CLIENT_ID
              value: "__CLIENT_ID__"
            - name: AZURE_TENANT_ID
              value: "__TENANT_ID__"
            - name: AZURE_CLIENT_CERTIFICATE_PATH
              value: /var/run/cert/cert.pem
            - name: FOUNDRY_ENDPOINT
              value: "__ENDPOINT__"
            - name: FOUNDRY_DEPLOYMENT
              value: "__DEPLOYMENT__"
            - name: TOKEN_RETRIES
              value: "__RETRIES__"
          volumeMounts:
            - name: app
              mountPath: /app
            - name: cert
              mountPath: /var/run/cert
              readOnly: true
      volumes:
        - name: app
          configMap:
            name: cert-demo-app
        - name: cert
          secret:
            secretName: __SECRET__
