### Clone the Repository

git clone git@github.com:tiiuae/ci-yubi.git

cd ci-yubi

git checkout feature/uefi-deployed

git pull origin feature/uefi-deployed

cd secboot/uefi-deployed-mode


### Prepare the Shared Folder

Create an output subfolder and copy your ISO image into it:

mkdir out
cp /path/to/your.iso out/

### Build the Docker image

from uefi-deployed-mode folder, build the Docker image

docker build --network=host  -t softhsm-secboot:latest .

### Run the Docker Container

Start the container with the shared folder mounted:

docker run --network=host -v "${PWD}/out:/root/out" --rm -it softhsm-secboot:latest /bin/bash

### Run the Demo Script

inside the container:

./demo.sh

### Exit the Container and Provision UEFI

After exiting the Docker container, the shared out folder will contain:

  - All generated .esl and .auth files
  - The signed Ghaf image, located in the out/signed subdirectory

You can now proceed with provisioning your UEFI environment using these signed artifacts.
