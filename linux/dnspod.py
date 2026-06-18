import sys
import json
import urllib.request
import urllib.error
import hashlib
import hmac
import datetime
import time
import os

def get_config():
    config_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config.json")
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)

def get_credentials(config):
    secret_id = os.environ.get("CF_SECRET_ID", config.get("SecretId", ""))
    secret_key = os.environ.get("CF_SECRET_KEY", config.get("SecretKey", ""))
    return secret_id, secret_key

def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

def invoke_api(action, payload):
    try:
        config = get_config()
    except Exception as e:
        return {"Response": {"Error": {"Code": "ConfigError", "Message": str(e)}}}
        
    secret_id, secret_key = get_credentials(config)
    service = "dnspod"
    version = "2021-03-23"
    host = "dnspod.tencentcloudapi.com"
    algorithm = "TC3-HMAC-SHA256"
    
    timestamp = int(time.time())
    date = datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).strftime("%Y-%m-%d")
    
    payload_str = json.dumps(payload, separators=(',', ':'))
    
    # 1. build canonical request
    http_request_method = "POST"
    canonical_uri = "/"
    canonical_querystring = ""
    canonical_headers = f"content-type:application/json; charset=utf-8\nhost:{host}\n"
    signed_headers = "content-type;host"
    hashed_request_payload = hashlib.sha256(payload_str.encode("utf-8")).hexdigest()
    canonical_request = f"{http_request_method}\n{canonical_uri}\n{canonical_querystring}\n{canonical_headers}\n{signed_headers}\n{hashed_request_payload}"
    
    # 2. build string to sign
    credential_scope = f"{date}/{service}/tc3_request"
    hashed_canonical_request = hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
    string_to_sign = f"{algorithm}\n{timestamp}\n{credential_scope}\n{hashed_canonical_request}"
    
    # 3. sign string
    secret_date = sign(("TC3" + secret_key).encode("utf-8"), date)
    secret_service = sign(secret_date, service)
    secret_signing = sign(secret_service, "tc3_request")
    signature = hmac.new(secret_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    
    # 4. build authorization
    authorization = f"{algorithm} Credential={secret_id}/{credential_scope}, SignedHeaders={signed_headers}, Signature={signature}"
    
    headers = {
        "Authorization": authorization,
        "Content-Type": "application/json; charset=utf-8",
        "X-TC-Action": action,
        "X-TC-Version": version,
        "X-TC-Timestamp": str(timestamp)
    }
    
    req = urllib.request.Request(f"https://{host}", data=payload_str.encode("utf-8"), headers=headers)
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return json.loads(e.read().decode("utf-8"))
    except Exception as e:
        return {"Response": {"Error": {"Code": "RequestError", "Message": str(e)}}}

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(json.dumps({"Response": {"Error": {"Code": "InvalidArgs", "Message": "Missing action or payload"}}}))
        sys.exit(1)
        
    action = sys.argv[1]
    try:
        payload = json.loads(sys.argv[2])
    except Exception as e:
        print(json.dumps({"Response": {"Error": {"Code": "InvalidPayload", "Message": "Payload is not valid JSON"}}}))
        sys.exit(1)
        
    res = invoke_api(action, payload)
    print(json.dumps(res))
