FROM ubuntu:noble

WORKDIR /app
RUN mkdir /etc/nitrokey
COPY p11nethsm.conf /etc/nitrokey/p11nethsm.conf
COPY openssl.cnf /etc/nitrokey/openssl.cnf


RUN DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y \
    software-properties-common \
    wget iputils-ping \
    pkgconf libssl-dev \
    opensc libengine-pkcs11-openssl

RUN wget https://github.com/Nitrokey/nethsm-pkcs11/releases/download/v1.5.0/nethsm-pkcs11-vv1.5.0-x86_64-debian.12.so
RUN cp nethsm-pkcs11-vv1.5.0-x86_64-debian.12.so /usr/lib/x86_64-linux-gnu/pkcs11/libnethsm_pkcs11.so

RUN echo "alias p='pkcs11-tool --module /usr/lib/x86_64-linux-gnu/pkcs11/libnethsm_pkcs11.so --login --login-type so --so-pin Administrator'" >> ~/.bashrc
RUN echo "alias pd='RUST_LOG=debug pkcs11-tool --module /usr/lib/x86_64-linux-gnu/pkcs11/libnethsm_pkcs11.so --login --login-type so --so-pin Administrator'" >> ~/.bashrc
RUN echo "export P11NETHSM_CONFIG_FILE=/etc/nitrokey/p11nethsm.conf" >> ~/.bashrc
RUN echo "export OPENSSL_CONF=/etc/nitrokey/openssl.cnf" >> ~/.bashrc
