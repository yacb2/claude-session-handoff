---
description: Cierra la sesión actual y abre una nueva, sembrando contexto de handoff
argument-hint: [prompt opcional — si va vacío, Claude lo genera del contexto actual]
allowed-tools: Bash(sh:*), Bash(printf:*), Bash(touch:*), Bash(kill:*), Bash(mkdir:*), Bash(test:*), Write
---

# /handoff

Cierra esta sesión y abre una nueva sesión limpia con un prompt de handoff sembrado como contexto inicial. Más rápido y barato que `/compact` cuando solo necesitas continuar el trabajo en un contexto fresco.

## Cómo proceder

Revisa `$ARGUMENTS`:

**Si `$ARGUMENTS` tiene contenido**, úsalo tal cual como payload de handoff.

**Si `$ARGUMENTS` está vacío**, redacta tú el prompt de handoff. Usa esta estructura mínima — solo información que la próxima sesión NO puede derivar leyendo el código o `CLAUDE.md`:

```
## Objetivo actual
<una frase>

## Estado
<archivos tocados, qué quedó hecho, qué falta>

## Decisiones tomadas
<lista corta — solo lo no obvio del código>

## Próximo paso concreto
<acción única, accionable>

## Restricciones / gotchas
<lo que la próxima sesión pisaría si no lo supiera>
```

Sé breve. Cada frase tiene que ganarse su lugar.

## Ejecuta el handoff

Con el payload listo, escríbelo al archivo de payload, crea el flag y manda SIGTERM al wrapper. **Importante**: `$CLAUDE_HANDOFF_ID` tiene que estar seteado — si no, el wrapper no está corriendo y no podemos cerrar.

```sh
if [ -z "$CLAUDE_HANDOFF_ID" ]; then
  echo "handoff: no se detectó el wrapper. Lanza claude vía la función del shell que instala claude-session-handoff." >&2
  exit 1
fi

mkdir -p "$HOME/.claude/tmp"
PAYLOAD_FILE="$HOME/.claude/tmp/handoff-payload-$CLAUDE_HANDOFF_ID"
FLAG_FILE="$HOME/.claude/tmp/handoff-flag-$CLAUDE_HANDOFF_ID"

# Escribe el payload usando un heredoc con delimitador único para evitar
# expansión de variables y conflictos con comillas dentro del prompt.
cat > "$PAYLOAD_FILE" <<'__HANDOFF_PAYLOAD_EOF__'
<EL PROMPT DE HANDOFF VA AQUÍ>
__HANDOFF_PAYLOAD_EOF__

touch "$FLAG_FILE"
kill -TERM $PPID
```

Después de mandar `kill -TERM`, no agregues más output — el wrapper va a cerrar este proceso y levantar una sesión nueva.
