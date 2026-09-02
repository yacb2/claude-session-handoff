---
description: Cierra la sesión actual y abre una nueva, sembrando contexto de handoff
argument-hint: [prompt opcional — si va vacío, Claude lo genera del contexto actual]
allowed-tools: Bash(sh:*), Bash(printf:*), Bash(touch:*), Bash(mkdir:*), Bash(test:*), Bash(cat:*), Bash(umask:*), Bash(ps:*), Bash(tr:*), Write
---

# /handoff

Cierra esta sesión y abre una nueva sesión limpia con un prompt de handoff sembrado como contexto inicial. Más rápido y barato que `/compact` cuando solo necesitas continuar el trabajo en un contexto fresco.

## Cómo proceder

Revisa `$ARGUMENTS`:

**Si `$ARGUMENTS` tiene contenido**, úsalo tal cual como payload de handoff.

**Si `$ARGUMENTS` está vacío**, redacta tú el prompt de handoff. Usa esta estructura mínima — solo información que la próxima sesión NO puede derivar leyendo el código o `CLAUDE.md`:

```
slug: <cómo se llama esta cadena de sesiones>

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

La línea `slug:` nombra la cadena y es la única que lee el mecanismo: el hook `SessionStart` la
toma de las primeras cinco líneas del brief, le antepone el ordinal que lee de
`~/.claude/handoff-chains/`, y eso queda como título de la sesión en el picker de `--resume`
(`↻3 · Refactor auth`). Sin ella la sesión nueva se autotitula con su primer prompt — la palabra
*continue* — y una cadena de cinco sesiones se ve como cinco filas idénticas.

Mantén el slug actual de la cadena salvo que cambie el **tema** del trabajo: una fase nueva del
mismo trabajo no es un tema nuevo. Una línea, sin ordinal propio — el ordinal sale del registro.

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

Con el payload listo, escríbelo al archivo de payload, crea el flag, y toca el archivo de exit-trigger. **Importante**: no alcanza con que `$CLAUDE_HANDOFF_ID` esté definida. El wrapper la exporta como su propio PID y **todo descendiente la hereda**, incluidas sesiones que el wrapper nunca lanzó ni supervisa (`--fork-session`, `--resume`, un job en background del harness): ahí la variable está definida y su wrapper ya murió. Lo que distingue "mi wrapper me está mirando" de "aquí corrió un wrapper alguna vez" es la ascendencia, así que el bloque recorre la cadena de padres.

```sh
# `test -z`, no `[ -z ]`: the allowed-tools matcher treats `[` as a different
# command word from `test`, and only `test` is declared. Same reason `printf`
# stands in for `echo` below.
if test -z "$CLAUDE_HANDOFF_ID"; then
  printf '%s\n' "handoff: no se detectó el wrapper. Lanza claude vía la función del shell que instala claude-session-handoff." >&2
  exit 1
fi

# Mismo chequeo que is_wrapper_ancestor() en handoff-prompt-hook.sh, escrito
# con las palabras de comando que allowed-tools declara: una variable seteada
# solo prueba que hubo un wrapper arriba en el árbol, no que el mío siga vivo.
is_wrapper_ancestor() {
  _pid=$$
  while _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' '); test -n "$_pid"; do
    case "$_pid" in
      0|1) return 1 ;;
    esac
    test "$_pid" = "$CLAUDE_HANDOFF_ID" && return 0
  done
  return 1
}

if ! is_wrapper_ancestor; then
  printf '%s\n' "handoff: el wrapper PID $CLAUDE_HANDOFF_ID no es ancestro de esta sesión (variable heredada o stale). No se escribió nada y esta sesión no se va a cerrar." >&2
  exit 1
fi

mkdir -p "$HOME/.claude/tmp"

# El payload es contenido de la conversación. Claude Code guarda los transcripts
# en 0600; el umask por defecto lo escribiría 0644, más legible que su origen.
umask 077

# Deltas del libro de cadena (chain ledger). Verbos, uno por línea:
#   OPEN OWED <texto>  decisión que solo el usuario puede tomar, aún sin responder
#   OPEN RULE <texto>  restricción vigente que el usuario dictó
#   CLOSE d<n> <cómo>  el item d<n> que mostró el bloque CHAIN LEDGER quedó resuelto
#   TURN <texto>       el trabajo cambió de rumbo (no es una obligación, nada lo cierra)
#   CHARTER <texto>    para qué existe la cadena; solo en el primer handoff
# El detalle está en la sección "The chain ledger" del skill session-handoff.
# Deltas del libro de cadena. Mismo patrón de dejar un archivo que el payload,
# y por el mismo motivo: esta sesión no conoce ni su id ni su cadena, así que no
# puede indexar un libro. El hook de SessionStart — el único lugar donde existe
# la identidad de cadena — los aplica. OMITE este cat entero si nada cambió.
DELTA_FILE="$HOME/.claude/tmp/handoff-ledger-$CLAUDE_HANDOFF_ID"
cat > "$DELTA_FILE" <<'__HANDOFF_DELTA_EOF__'
<UN DELTA POR LÍNEA — OPEN / CLOSE / TURN / CHARTER — U OMITE ESTE BLOQUE ENTERO>
__HANDOFF_DELTA_EOF__

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

Mira el exit status del bloque antes de decidir qué decir. Distinto de cero significa que se negó y ya imprimió por qué: no se escribió nada, esta sesión no se cierra, y quedarte callado deja al usuario mirando un handoff que nunca ocurrió. Reporta el motivo en ese mismo turno y para.

Solo con exit 0, después de tocar `$EXIT_TRIGGER`, no agregues más output — el watcher del wrapper detecta el archivo en ~0.5s, manda SIGTERM a claude, y levanta la sesión nueva.
