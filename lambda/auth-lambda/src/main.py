import os
import boto3
import json

USER_POOL_ID = os.environ['USER_POOL_ID']
CLIENT_ID = os.environ['CLIENT_ID']

def lambda_handler(event, context):
    try:
        body = json.loads(event['body'])
        cpf = body.get('cpf')
        
        if not cpf:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'CPF não fornecido'})
            }
        
        # Remove caracteres não numéricos
        clean_cpf = ''.join(filter(str.isdigit, cpf))
        
        client = boto3.client('cognito-idp')
        
        try:
            # Tenta autenticar o usuário
            response = client.admin_initiate_auth(
                UserPoolId=USER_POOL_ID,
                ClientId=CLIENT_ID,
                AuthFlow='CUSTOM_AUTH',
                AuthParameters={
                    'USERNAME': clean_cpf
                }
            )
        except client.exceptions.UserNotFoundException:
            # Cria o usuário se não existir
            client.admin_create_user(
                UserPoolId=USER_POOL_ID,
                Username=clean_cpf,
                UserAttributes=[{'Name': 'custom:cpf', 'Value': clean_cpf}],
                MessageAction='SUPPRESS'
            )
            # Tenta autenticar novamente
            response = client.admin_initiate_auth(
                UserPoolId=USER_POOL_ID,
                ClientId=CLIENT_ID,
                AuthFlow='CUSTOM_AUTH',
                AuthParameters={
                    'USERNAME': clean_cpf
                }
            )
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'access_token': response['AuthenticationResult']['AccessToken'],
                'id_token': response['AuthenticationResult']['IdToken']
            })
        }
        
    except Exception as e:
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }