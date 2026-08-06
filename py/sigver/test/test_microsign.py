# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
# SPDX-License-Identifier: Apache-2.0
""" Signature Verification Microservice Tests """
import subprocess
import time
import pytest

# Constants for production and staging URLs
STAGING_SLOT_URL = "https://ghaf-devenv-microsign-aleksandrtserepo-app.azurewebsites.net/api/verify-signature" # pylint: disable=line-too-long
PRODUCTION_SLOT_URL = "https://ghaf-devenv-signverify.azurewebsites.net/api/verifysignature"

# Test configuration
MAX_RETRIES = 3  # Max number of retries in case of failure
SLEEP_INTERVAL = 5  # Time to wait between retries or requests (seconds)

@pytest.fixture(scope="session")
def retry_config():
    """ Fixture to define the maximum retries and sleep interval """
    return {
        'max_retries': MAX_RETRIES,
        'sleep_interval': SLEEP_INTERVAL
    }

def run_verification_script(url):
    """ Function to run step.py script with --url parameter """
    try:
        result = subprocess.run(['python3', 'step.py', f'--url={url}'],
                                capture_output=True, check=True)
        return result.returncode
    except subprocess.CalledProcessError as e:
        print(f"Exception while running step.py for {url}: {e}")
        return -2  # Return code for exception

def run_test_with_retries(url, max_retries, sleep_interval):
    """  Function to run verification with retry logic """
    retry_count = 0
    while retry_count < max_retries:
        result_code = run_verification_script(url)
        if result_code == 0:
            print(f"Test passed for {url}.")
            return True
        if result_code == -5:
            print(f"Received 503 from {url}. Retrying... (retry count: {retry_count + 1})")
            retry_count += 1
            time.sleep(sleep_interval)
        else:
            print(f"Test failed for {url} with code: {result_code}.")
            return False
    print(f"Test failed for {url} after {max_retries} retries.")
    return False

def test_cold_start_scaling(retry_config): # pylint: disable=redefined-outer-name
    """ Test case 1: Cold start and scaling test """
    success = run_test_with_retries(PRODUCTION_SLOT_URL,
                                    retry_config['max_retries'],
                                    retry_config['sleep_interval'])
    assert success, "Production slot failed the cold start/scaling test."

def test_slot_verification(retry_config): # pylint: disable=redefined-outer-name
    """ Test case 2: Slot verification (both production and staging) """
    success_prod = run_test_with_retries(PRODUCTION_SLOT_URL,
                                         retry_config['max_retries'],
                                         retry_config['sleep_interval'])

    success_staging = run_test_with_retries(STAGING_SLOT_URL,
                                            retry_config['max_retries'],
                                            retry_config['sleep_interval'])

    assert success_prod, "Production slot failed the slot verification test."
    assert success_staging, "Staging slot failed the slot verification test."
