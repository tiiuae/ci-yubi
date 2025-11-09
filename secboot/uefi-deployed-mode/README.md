### Build docker

docker build --network=host --build-arg TOKEN_LABEL=UEFI-Token --build-arg SO_PIN=3537363231383830 --build-arg USER_PIN=123456 -t softhsm-secboot:latest .

### Run docker

docker run --network=host -v "${PWD}/out:/work/out --rm -it softhsm-secboot:latest /bin/bash

### Run ./demo.sh

./demo.sh
