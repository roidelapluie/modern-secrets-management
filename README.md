# Modern Secrets Management

This repository contains all the materials and a rough outline for my
[2017 OSDC Berlin talk][talk] which discusses using Vault for modern secrets
management.

This outline was written in advance of the presentation, so questions or
digressions may not be captured here in the fullest.

These configurations use Vault 0.7.2, but the concepts are largely applicable to
all Vault releases.

Finally **these are not best practice Terraform configurations. These are for
demonstration purposes only and should not be used in production.**

## In Advance

- Make sure 1password is unlocked and on the "Demo Vault" vault

## Getting Started

I have configured a Vault server in advance that is already running and
listening. We can check the status of the Vault server by running:

```shell
$ vault status
```

It looks like we are ready to go!

## Authenticating

The first thing we need to do is authenticate to Vault. For this demo, we will
login via the root user. This is not a best practice.

```
$ vault auth root
```

There are many ways to authenticate to Vault including GitHub,
username-password, LDAP, and more. There are also ways for machines to
authenticate such as AppID or TLS.

The root user is special and has all permissions in the system. Other users must
be granted access via policies, which we will explore in a bit.

## Static Secrets

As mentioned, Vault can act as encrypted redis/memcached. This data is encrypted
in transit and at rest, and Vault stores the data.

```
$ vault write secret/foo value=super-secret
```

This mount supports basic CRUD operations:

```
$ vault read secret/foo
```

```
$ vault write secret/foo value=new-value
```

```
$ vault list secret/
```

```
$ vault delete secret/foo
```

## Semi-Static Secrets

Vault can also provide encryption as a service. In this model, Vault encrypts
the data, but it does not _store_ it. Instead the encrypted data is returned in
the response, and it is the caller's responsibility to store the data (perhaps
in a database).

The advantage here is that applications do not need to know how to do asymmetric
encryption nor do they applications even know the encryption key. An attacker
would need to compromise multiple systems to decrypt the data.

First we need to mount the "transit" backend. The backend is called "transit"
because data flows through it.

```
$ vault mount transit
```

Next, we need to create a named key. This key is like a symbolic link to an
encryption key or set of encryption keys. The transit backend supports key
rotation and upgrading, so the name is a human identifier around that.

```
$ vault write -f transit/keys/my-key
```

Now we can feed data into this named key, and Vault will return the encrypted
data. Because there is no requirement the data be "text", we need to pass
base64-encoded data.

```
$ vault write transit/encrypt/my-key plaintext=$(base64 <<< "foo")
```

Vault returns the base64-encoded ciphertext. This ciphertext can be stored in
our database or filesystem. When our application needs the plaintext value, it
can post the encrypted value and get the plaintext back.

```
$ vault write transit/decrypt/my-key ciphertext="..."
```

And then `base64 -d` that value.

```
$ base64 -d <<< "..."
```

The transit endpoint also supports "derived" keys, which enables each piece of
data to be encrypted with a unique "context". This context generates a new
encryption key. Each record then has a unique encryption key, but Vault does not
have the overhead of managing millions of encryption keys because they are
derived from a parent key.

Example: rows in a database

## Dynamic Secrets

### PostgreSQL

Vault also has the ability to _generate_ secrets. These are called "dynamic"
secrets. Unlike static secrets, dynamic secrets have an expiration, called a
lease. At the end of this lease, the credential is revoked. This prevents secret
sprawl and significantly reduces the attack surface. Instead of a database
password living in a text file for 6 months, it can be dynamically generated
every 30 minutes!

Let's use postgres as an example. First we mount the database backend:

```
$ vault mount database
```

And configure the mount to talk to a postgres database

```
$ cat setup-pg-connection.sh
vault write database/config/postgresql \
  plugin_name="postgresql-database-plugin" \
  connection_url="postgresql://postgres@localhost:5432/myapp" \
  allowed_roles="readonly"

$ ./setup-pg-connection.sh
```

Next we create a role. We tell Vault what SQL to run to create our user.

```
$ cat setup-pg-role.sh
vault write database/roles/readonly \
  db_name="postgresql" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"

# ./setup-pg-role.sh
```

Now read from this endpoint and Vault will dynamically generate a postgres
login:

```
$ vault read database/creds/readonly
```

These are real postgresql credentials. We can login to postgres to verify:

```
$ psql -U postgres
```

### AWS IAM

Vault can do more than generate database credentials - it can also communicate
with third-party APIs to generate credentials, such as AWS IAM.

First we need to mount the backend:

```
$ vault mount aws
```

Then we need to give Vault a user which has permission to generate IAM users.

```
$ cat setup-aws-connection.sh
vault write aws/config/root \
  access_key="$AWS_ACCESS_KEY_ID" \
  secret_key="$AWS_SECRET_ACCESS_KEY" \
  region="$AWS_REGION"

$ ./setup-aws-connection.sh
```

Then we create a role which assigns a given IAM policy to a user upon creation.
Here is the sample IAM policy.

```
$ cat iam-policy.json
```

And we create the role named "user" by running

```
$ vault write aws/roles/user policy=@iam-policy.json
```

The `@` tells Vault to read from a file.

Now when we read from this endpoint, Vault will connection to AWS and generate
an IAM pair, returning the result to the terminal.

```
$ vault read aws/creds/user
```

These leases seem long - let's fix that.

```
$ vault write aws/config/lease lease=30s lease_max=5m
```

Now create another user and observe the lease_duration field

```
$ vault read aws/creds/user
```

We can also revoke all these credentials, perhaps in a break glass scenario:

```
$ vault revoke -prefix aws/
```

### Certificate Authority

Vault can also be used as a full certificate authority (CA).

The PKI backend requires a pre-existing cert and a decent understanding of PKI
principles. For the purposes of this demo, we'll cheat and encapsulate that
logic in a script.

```
$ ./setup-pki.sh
```

Now we can generate a certificate for a given common name

```
$ vault write pki/issue/my-website \
    common_name="www.example.com"
```

Because these are just API requests under the hood, it is possible to make API
requests, retrieve certificates, and only persist them in-memory.

### TOTP Generator

A recent feature in Vault is the ability to generate OTP codes, such as MFA
codes or 2FA codes. In this way, it could be used to replace something like
Google Authenticator or Authy. First we mount the backend:

```
$ vault mount totp
```

Next, provide the OTP key url. You may be familiar with the "barcode" approach
in which you scan a QR-like code to generate the OTP. That QR code is actually
just an encoded URL that looks like this:

```
$ cat ./otp-url.txt
otpauth://totp/Vault:seth@sethvargo.com?secret=Y64VEVMBTSXCYIWRSHRNDZW62MPGVU2G&issuer=Vault
```

We can write this to Vault

```
$ vault write totp/keys/demo \
    url=@otp-url.txt
```

Now, read from this endpoint at any point in time to get the OTP code.

```
$ vault read totp/code/demo
```

### TOTP Authenticator

Vault can also act as a TOTP provider:

```
$ vault write totp/keys/my-app \
    generate=true \
    issuer=Vault \
    account_name=seth@sethvargo.com
```

This will return two results - a base64-encoded barcode and a URL. Either of
these may be used with a password manager. I'll use 1Password.

To generate the image, copy it to your clipboard. then decode it into a file
_on the local system_.

```
$ base64 --decode <<< "..." > qr.png

$ open qr.png
```

Now I'll open up 1Password and create a new login and scan this code.

And then we can validate the code:

```
$ vault write totp/code/my-app code=127388
```

## Vault UI

Time permitting, show the Vault UI at https://vault.hashicorp.rocks.

[talk]: https://www.netways.de/en/events/osdc/program/seth_vargo_modern_secrets_management_with_vault/
