#!/usr/bin/env python3

import requests
import json

def test_anthropic_key(api_key):
    url = "https://api.anthropic.com/v1/messages"
    
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
        "anthropic-version": "2023-06-01"
    }
    
    payload = {
        "model": "claude-3-haiku-20240307",
        "max_tokens": 10,
        "messages": [
            {
                "role": "user",
                "content": "Hello"
            }
        ]
    }
    
    print("🔑 Testing Anthropic API Key with Python")
    print("=" * 40)
    print(f"URL: {url}")
    print(f"Model: {payload['model']}")
    print(f"Max tokens: {payload['max_tokens']}")
    print()
    
    try:
        response = requests.post(url, headers=headers, json=payload, timeout=30)
        
        print(f"Status Code: {response.status_code}")
        print(f"Response Headers: {dict(response.headers)}")
        print()
        
        if response.status_code == 200:
            print("✅ API key is VALID!")
            data = response.json()
            print(f"Response: {json.dumps(data, indent=2)}")
        elif response.status_code == 401:
            print("❌ API key is INVALID - 401 Unauthorized")
            print(f"Error: {response.text}")
        else:
            print(f"⚠️  Unexpected status: {response.status_code}")
            print(f"Body: {response.text}")
            
    except requests.exceptions.RequestException as e:
        print(f"❌ Request failed: {e}")
    except json.JSONDecodeError as e:
        print(f"❌ JSON decode error: {e}")

if __name__ == "__main__":
    api_key = "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"
    test_anthropic_key(api_key)