---
description: Cierra la sesión actual y abre una nueva, sembrando contexto de handoff
argument-hint: [prompt opcional — si va vacío, Claude lo genera del contexto actual]
allowed-tools: Bash(sh:*), Bash(printf:*), Bash(touch:*), Bash(mkdir:*), Bash(test:*), Bash(cat:*), Bash(umask:*), Write
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
<acción única, accionable — o, si el próximo paso es una decisión que solo el
usuario puede tomar, nómbrala como tal: las opciones, qué cuesta cada una, y qué
está ya verificado>

## Restricciones / gotchas
<lo que la próxima sesión pisaría si no lo supiera>
```

Sé breve. Cada frase tiene que ganarse su lugar. La única sección que nunca se omite es
`Próximo paso concreto`: contesta *¿el próximo paso es mío o del usuario?* y escribe la
respuesta. Una bifurcación registrada es una respuesta válida; una implícita no lo es.
Las dos mitades importan: omitir la sección esconde una bifurcación que la sesión nueva
tiene que redescubrir sola, e inventar un paso único para llenar el hueco hace que ejecute
una decisión que el usuario nunca tomó. Cuidado con la vía silenciosa: degradar la
bifurcación a `Restricciones / gotchas` como prohibición — *"no publiques sin permiso"* —
deja a la sesión nueva leyendo una regla donde había una decisión esperando.

**Si el usuario está presente, resuelve la bifurcación aquí en vez de registrarla.** Acaba de
pedir el handoff: está a un turno. Pregunta qué hilo sigue y haz el handoff en el turno
siguiente con su respuesta escrita como paso único — la sesión nueva abre ejecutando, no
abre con un menú. Registrarla es el fallback para cuando preguntar no se puede.

Pregunta **una sola vez**, y solo sobre **qué hilo sigue** — nunca sobre si hacer el handoff.
"Una sola vez" es cómo preguntas, no cuán bifurcado está el estado: varias decisiones abiertas
no son varias preguntas ni descalifican preguntar, son **una** pregunta con varias opciones.
Tocar `$EXIT_TRIGGER` cierra la sesión en ~0.5s, así que preguntar pospone el handoff un turno:
hazlo solo cuando de verdad hay bifurcación.

## Ejecuta el handoff

Con el payload listo, escríbelo al archivo de payload, crea el flag, y toca el archivo de exit-trigger. **Importante**: `$CLAUDE_HANDOFF_ID` tiene que estar seteado — si no, el wrapper no está corriendo y no podemos cerrar.

```sh
# `test -z`, no `[ -z ]`: the allowed-tools matcher treats `[` as a different
# command word from `test`, and only `test` is declared. Same reason `printf`
# stands in for `echo` below.
if test -z "$CLAUDE_HANDOFF_ID"; then
  printf '%s\n' "handoff: no se detectó el wrapper. Lanza claude vía la función del shell que instala claude-session-handoff." >&2
  exit 1
fi

mkdir -p "$HOME/.claude/tmp"

# El payload es contenido de la conversación. Claude Code guarda los transcripts
# en 0600; el umask por defecto lo escribiría 0644, más legible que su origen.
umask 077

PAYLOAD_FILE="$HOME/.claude/tmp/handoff-payload-$CLAUDE_HANDOFF_ID"
FLAG_FILE="$HOME/.claude/tmp/handoff-flag-$CLAUDE_HANDOFF_ID"
EXIT_TRIGGER="$HOME/.claude/tmp/handoff-exit-$CLAUDE_HANDOFF_ID"

# Escribe el payload usando un heredoc con delimitador único para evitar
# expansión de variables y conflictos con comillas dentro del prompt.
cat > "$PAYLOAD_FILE" <<'__HANDOFF_PAYLOAD_EOF__'
<EL PROMPT DE HANDOFF VA AQUÍ>
__HANDOFF_PAYLOAD_EOF__

touch "$FLAG_FILE"
touch "$EXIT_TRIGGER"
```

Después de tocar `$EXIT_TRIGGER`, no agregues más output — el watcher del wrapper detecta el archivo en ~0.5s, manda SIGTERM a claude, y levanta la sesión nueva.
