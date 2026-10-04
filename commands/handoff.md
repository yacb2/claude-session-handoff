---
description: Cierra la sesión actual y abre una nueva, sembrando contexto de handoff
argument-hint: [prompt opcional — si va vacío, Claude lo genera del contexto actual]
allowed-tools: Skill
---

# /handoff

Carga el skill `session-handoff` y síguelo como un **Direct trigger**: el usuario pidió el handoff, ejecútalo.

Pasa `$ARGUMENTS` tal cual como el brief que escribió el usuario. Si viene vacío, el skill indica cómo redactar el brief desde el contexto actual.

Este comando no lleva reglas ni bloque de ejecución propios: el skill es la única fuente (redacción del brief, bifurcación, libro de cadena y disparo).
