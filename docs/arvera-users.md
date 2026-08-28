# Usuarios Arvera

Este despliegue distingue dos tipos de usuario:

1. Usuario con buzon propio
   - Tiene `maildir`.
   - Puede iniciar sesion en grommunio Web de forma normal.
   - Puede recibir correo propio si el dominio/ruta de entrada lo entrega ahi.
   - Puede tener permisos sobre buzones compartidos como `info@arvera.es` y `admin@arvera.es`.

2. Usuario operador sin buzon propio
   - Se crea con `--no-maildir`.
   - No consume una tienda de correo local.
   - Puede figurar como delegado y como autorizado para enviar como buzones compartidos.
   - El webmail oficial espera una tienda MAPI por defecto; por eso el login directo de este tipo de usuario requiere la adaptacion Arvera de grommunio-web/MAPI.

Scripts disponibles:

```bash
OPERATOR_EMAIL=francisco@arvera.es \
OPERATOR_DISPLAY="Francisco J Nunez" \
./scripts/create_operator_user.sh
```

```bash
MAILBOX_EMAIL=francisco@arvera.es \
MAILBOX_DISPLAY="Francisco J Nunez" \
./scripts/create_mailbox_user.sh
```

Ambos scripts conceden, por defecto, permisos sobre:

```text
info@arvera.es
admin@arvera.es
```

Para cambiarlo:

```bash
SHARED_MAILBOXES="info@arvera.es admin@arvera.es otro@arvera.es" \
OPERATOR_EMAIL=operador@arvera.es \
./scripts/create_operator_user.sh
```

Pendiente tecnico:

- Adaptar grommunio-web para que un usuario sin `maildir` pueda iniciar sesion usando un buzon compartido autorizado como tienda efectiva.
- Verificar si Gromox/MAPI permite abrir la tienda compartida sin depender de `getDefaultMessageStore()` del usuario operador.
- Si no lo permite, la alternativa correcta es una pequena capa Arvera de operador que autentique al usuario y abra los buzones compartidos mediante un backend propio.
