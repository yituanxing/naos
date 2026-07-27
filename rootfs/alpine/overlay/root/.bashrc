source /etc/profile

if [ -z "${TERM}" ] || [ "${TERM}" = dumb ]; then
    export TERM=linux
fi

export SDL_AUDIODRIVER=dummy

NORMAL="\[\e[0m\]"
RED="\[\e[1;31m\]"
GREEN="\[\e[1;32m\]"
if [ "$EUID" -eq 0 ]; then
    PS1="$RED\u@\h [ $NORMAL\w$RED ]# $NORMAL"
else
    PS1="$GREEN\u@\h [ $NORMAL\w$GREEN ]\$ $NORMAL"
fi
unset RED GREEN NORMAL

alias ls='ls --color=auto'
alias grep='grep --color=auto'
