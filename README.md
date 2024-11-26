# folio-keycloak

## Introduction

A docker image for keycloak installation

## Add custom theme 

Copy `custom-theme` folder to /opt/jboss/keycloak/themes/

### Run container in docker

Build application with:

```shell
docker build -t folio-keycloak .
```


### Additional variables for container

| METHOD                           | REQUIRED | DEFAULT VALUE                                                   | DESCRIPTION                 |
|:---------------------------------|:--------:|:----------------------------------------------------------------|:----------------------------|
| KC_FOLIO_BE_ADMIN_CLIENT_ID      |  false   | folio-backend-admin-client                                      | Folio backend client id     |
| KC_FOLIO_BE_ADMIN_CLIENT_SECRET  |   true   | -                                                               | Folio backend client secret |
| KC_HTTPS_KEY_STORE_PASSWORD      |   true   | -                                                               | BCFSK Keystore password     |
| KCADM_HTTPS_TRUST_STORE_PASSWORD |  false   | SecretPassword                                                  | Truststore password         |
| KC_LOG_LEVEL                     |  false   | INFO,org.keycloak.common.crypto:TRACE,org.keycloak.crypto:TRACE | Keycloak log level          |

