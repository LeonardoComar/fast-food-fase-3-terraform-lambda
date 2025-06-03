import re
import requests
import jwt
import boto3
import os

def validate_cpf(cpf):
    cpf = re.sub(r'\D', '', cpf)
    if len(cpf) != 11 or not cpf.isdigit():
        return False
    if cpf == cpf[0] * 11:
        return False
    return True

def check_cpf_in_test_api(cpf):
    api_url = os.environ["API_URL"]
    try:
        response = requests.get(f"{api_url}?cpf={cpf}", timeout=30)
        if response.status_code == 200:
            return {"name": "Teste Usuario", "cpf": cpf}
        return None
    except requests.exceptions.RequestException as e:
        print(f"Error connecting to API: {e}")
        return None

def generate_jwt(payload, secret="SECRET"):
    token = jwt.encode(payload, secret, algorithm="HS256")
    return token

def create_user_in_cognito(username):
    client = boto3.client('cognito-idp')
    user_pool_id = os.environ["USER_POOLID"]
    try:
        response = client.admin_create_user(
            UserPoolId=user_pool_id,
            Username=username,
            UserAttributes=[
                {
                    'Name': 'email',
                    'Value': f"{username}@email.com"
                },
                {
                    'Name': 'email_verified',
                    'Value': 'true'
                }
            ]
        )
        print("User successfully created in Cognito.")
        return response
    except Exception as e:
        print(f"Error creating user in Cognito: {e}")
        raise

def store_token_in_cognito(username, token):
    client = boto3.client('cognito-idp')
    user_pool_id = os.environ["USER_POOLID"]
    try:
        response = client.admin_update_user_attributes(
            UserPoolId=user_pool_id,
            Username=username,
            UserAttributes=[
                {
                    'Name': 'custom:jwtToken',
                    'Value': token
                }
            ]
        )
        print("Token successfully stored in Cognito.")
        return response
    except client.exceptions.UserNotFoundException:
        print("User not found. Creating user...")
        create_user_in_cognito(username)
        return store_token_in_cognito(username, token)
    except Exception as e:
        print(f"Error storing token in Cognito: {e}")
        raise

def lambda_handler(event, context):
    cpf = event.get("queryStringParameters", {}).get("cpf")
    if not cpf:
        return {"statusCode": 400, "body": "CPF not provided"}

    if not validate_cpf(cpf):
        return {"statusCode": 401, "body": "Invalid CPF"}

    client_data = check_cpf_in_test_api(cpf)
    if client_data:
        token = generate_jwt(client_data)
        store_token_in_cognito(client_data["cpf"], token)
        return {"statusCode": 200, "body": f"JWT Token: {token}"}
    else:
        return {"statusCode": 404, "body": "CPF not found"}
