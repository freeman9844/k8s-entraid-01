apiVersion: batch/v1
kind: Job
metadata:
  name: __NAME__
  namespace: __NS__
spec:
  backoffLimit: 0
  template:
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
            - name: AZURE_CLIENT_ID
              value: "__CLIENT_ID__"
            - name: AZURE_TENANT_ID
              value: "__TENANT_ID__"
            - name: AZURE_AUTHORITY_HOST
              value: "https://login.microsoftonline.com/"
            - name: AZURE_FEDERATED_TOKEN_FILE
              value: /var/run/secrets/azure/tokens/azure-identity-token
          volumeMounts:
            - name: app
              mountPath: /app
            - name: azure-identity-token
              mountPath: /var/run/secrets/azure/tokens
              readOnly: true
      volumes:
        - name: azure-identity-token
          projected:
            sources:
              - serviceAccountToken:
                  audience: api://AzureADTokenExchange
                  expirationSeconds: 3600
                  path: azure-identity-token
        - name: app
          configMap:
            name: wif-demo-app
