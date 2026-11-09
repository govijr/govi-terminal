# Govi inline suggestions. MIT licensed; see the repository LICENSE.
# Runs only inside the interactive shell Govi started. No startup-file edits,
# external helper processes, eval, or terminal input injection are involved.
[[ -o interactive && -n ${GOVI_SUGGEST_SOCKET-} ]] || return 0
(( ${+_govi_inline_installed} )) && return 0

_govi_inline_setup() {
    builtin emulate -L zsh -o no_aliases
    builtin zmodload zsh/net/socket 2>/dev/null || return 0
    builtin zmodload zsh/system 2>/dev/null || return 0
    builtin zmodload zsh/zleparameter 2>/dev/null || return 0
    builtin autoload -Uz add-zle-hook-widget
    builtin typeset -gi _govi_inline_installed=1 _govi_inline_fd=-1
    builtin typeset -gi _govi_inline_sequence=0 _govi_inline_sent=0 _govi_inline_inflight=0
    builtin typeset -gi _govi_inline_searching=0
    builtin typeset -g _govi_inline_buffer='' _govi_inline_candidate='' _govi_inline_suffix=''
    builtin typeset -g _govi_inline_pending='' _govi_inline_suppressed='' _govi_inline_color=808080
    builtin typeset -gA _govi_inline_original_tabs

    _govi_inline_clear() {
        [[ ${POSTDISPLAY-} == "$_govi_inline_suffix" ]] && POSTDISPLAY=''
        region_highlight=("${(@)region_highlight:#*memo=govi-inline}")
        _govi_inline_suffix=''
        return 0
    }
    _govi_inline_valid() {
        [[ ${CONTEXT-} == start && ${KEYMAP-} != (vicmd|visual|menuselect|isearch) &&
           ${REGION_ACTIVE-0} == 0 && $_govi_inline_searching == 0 && -n $BUFFER && ${#BUFFER} -le 512 &&
           $BUFFER != *[[:cntrl:]]* && $BUFFER != [[:space:]]* &&
           $CURSOR -eq ${#BUFFER} && $BUFFER != "$_govi_inline_suppressed" ]]
    }
    _govi_inline_write() {
        (( _govi_inline_fd >= 0 )) || return 1
        builtin syswrite -o $_govi_inline_fd "$1" 2>/dev/null
    }
    _govi_inline_disconnect() {
        if (( _govi_inline_fd >= 0 )); then
            builtin zle -F $_govi_inline_fd 2>/dev/null
            builtin exec {_govi_inline_fd}>&-
        fi
        _govi_inline_fd=-1
        _govi_inline_inflight=0
        _govi_inline_pending=''
        builtin zle 2>/dev/null && _govi_inline_clear
        return 0
    }
    _govi_inline_connect() {
        builtin emulate -L zsh -o no_aliases
        _govi_inline_disconnect
        _govi_inline_buffer='' _govi_inline_candidate='' _govi_inline_suppressed=''
        _govi_inline_sent=0 _govi_inline_searching=0
        builtin zsocket "$GOVI_SUGGEST_SOCKET" 2>/dev/null || return 0
        _govi_inline_fd=$REPLY
        builtin zle -F -w $_govi_inline_fd govi-inline-receive
        return 0
    }
    _govi_inline_paint() {
        _govi_inline_clear
        if _govi_inline_valid && [[ $_govi_inline_candidate == "$BUFFER"* && $_govi_inline_candidate != "$BUFFER" ]]; then
            _govi_inline_suffix=${_govi_inline_candidate[$(( ${#BUFFER} + 1 )),-1]}
            POSTDISPLAY=$_govi_inline_suffix
            region_highlight+=("${#BUFFER} $(( ${#BUFFER} + ${#POSTDISPLAY} )) fg=#${_govi_inline_color} memo=govi-inline")
        fi
        return 0
    }
    _govi_inline_redraw() {
        builtin emulate -L zsh -o no_aliases
        if ! _govi_inline_valid; then
            _govi_inline_clear
            if [[ -n $_govi_inline_buffer ]]; then
                _govi_inline_buffer=''
                (( ++_govi_inline_sequence ))
                _govi_inline_write $'C\t'"$_govi_inline_sequence"$'\t\n'
            fi
            return 0
        fi
        if [[ $_govi_inline_buffer != "$BUFFER" ]]; then
            _govi_inline_buffer=$BUFFER
            (( ++_govi_inline_sequence ))
        fi
        _govi_inline_paint
        # Only one local request may be in flight. Typing never waits for an
        # answer, and we reuse a still-matching candidate while the user types.
        if (( _govi_inline_fd >= 0 && _govi_inline_inflight == 0 && _govi_inline_sent != _govi_inline_sequence )); then
            _govi_inline_sent=$_govi_inline_sequence
            _govi_inline_inflight=$_govi_inline_sequence
            _govi_inline_write $'Q\t'"$_govi_inline_sequence"$'\t'"$BUFFER"$'\n' || _govi_inline_disconnect
        fi
        return 0
    }
    _govi_inline_receive() {
        builtin emulate -L zsh -o no_aliases
        [[ -z ${2-} ]] || { _govi_inline_disconnect; return 0; }
        builtin local chunk line
        builtin local -a fields
        builtin sysread -i $_govi_inline_fd -s 8192 -t 0 chunk 2>/dev/null || { _govi_inline_disconnect; return 0; }
        _govi_inline_pending+=$chunk
        (( ${#_govi_inline_pending} <= 16384 )) || { _govi_inline_disconnect; return 0; }
        while [[ $_govi_inline_pending == *$'\n'* ]]; do
            line=${_govi_inline_pending%%$'\n'*}
            _govi_inline_pending=${_govi_inline_pending#*$'\n'}
            fields=("${(@ps:\t:)line}")
            [[ ${fields[1]-} == S && ${fields[2]-} == <-> ]] || continue
            [[ ${fields[2]} == $_govi_inline_inflight ]] && _govi_inline_inflight=0
            # Reject late results after editing, moving the cursor, accepting a
            # suggestion, changing keymap, or entering another prompt.
            if [[ ${fields[2]} == $_govi_inline_sequence && ${fields[4]-} == "$BUFFER" ]] && _govi_inline_valid; then
                if [[ ${#fields[3]} == 6 && ${fields[3]} != *[^[:xdigit:]]* ]]; then
                    _govi_inline_color=${fields[3]}
                fi
                _govi_inline_candidate=${fields[5]-}
                if [[ $_govi_inline_candidate == *[[:cntrl:]]* || ${#_govi_inline_candidate} -gt 512 ]]; then
                    _govi_inline_candidate=''
                fi
            fi
        done
        _govi_inline_redraw
        builtin zle -R
        return 0
    }
    _govi_inline_tab() {
        builtin emulate -L zsh -o no_aliases
        builtin local original=${_govi_inline_original_tabs[${WIDGET#govi-inline-tab-}]}
        if _govi_inline_valid && [[ -n $_govi_inline_suffix && ${POSTDISPLAY-} == "$_govi_inline_suffix" &&
              $_govi_inline_buffer == "$BUFFER" && $_govi_inline_candidate == "${BUFFER}${_govi_inline_suffix}" ]]; then
            BUFFER+=$_govi_inline_suffix
            CURSOR=${#BUFFER}
            _govi_inline_clear
            _govi_inline_suppressed=$BUFFER
            _govi_inline_candidate='' _govi_inline_buffer=''
            (( ++_govi_inline_sequence ))
            _govi_inline_write $'C\t'"$_govi_inline_sequence"$'\t\n'
            return 0
        fi
        _govi_inline_clear
        (( ++_govi_inline_sequence ))
        _govi_inline_write $'C\t'"$_govi_inline_sequence"$'\t\n'
        [[ -n $original ]] && builtin zle "$original" -w -- "$@"
        _govi_inline_suppressed=$BUFFER
        _govi_inline_buffer=''
        return 0
    }
    _govi_inline_finish() {
        _govi_inline_clear
        builtin zle -R
        _govi_inline_disconnect
        _govi_inline_buffer='' _govi_inline_candidate=''
        return 0
    }
    _govi_inline_search_update() {
        _govi_inline_searching=1
        _govi_inline_redraw
        return 0
    }
    _govi_inline_search_exit() {
        _govi_inline_searching=0
        _govi_inline_redraw
        return 0
    }
    _govi_inline_preexec() {
        # A short-lived connection records only the user's accepted command.
        # The editor connection is already closed, so no FD reaches programs.
        builtin emulate -L zsh -o no_aliases
        [[ -n $1 && ${#1} -le 512 && $1 != *[[:cntrl:]]* && $1 != [[:space:]]* ]] || return 0
        builtin zsocket "$GOVI_SUGGEST_SOCKET" 2>/dev/null || return 0
        builtin local fd=$REPLY
        builtin syswrite -o $fd $'H\t0\t'"$1"$'\n' 2>/dev/null
        builtin exec {fd}>&-
        return 0
    }

    builtin local keymap binding original
    builtin zle -N govi-inline-receive _govi_inline_receive
    for keymap in emacs viins main; do
        binding=$(builtin bindkey -M "$keymap" '^I' 2>/dev/null) || continue
        original=${binding##* }
        [[ $original != govi-inline-tab-* && -n ${widgets[$original]-} ]] || continue
        _govi_inline_original_tabs[$keymap]=$original
        builtin zle -N "govi-inline-tab-$keymap" _govi_inline_tab
        builtin bindkey -M "$keymap" '^I' "govi-inline-tab-$keymap"
    done
    add-zle-hook-widget line-init _govi_inline_connect
    add-zle-hook-widget line-pre-redraw _govi_inline_redraw
    add-zle-hook-widget line-finish _govi_inline_finish
    add-zle-hook-widget isearch-update _govi_inline_search_update
    add-zle-hook-widget isearch-exit _govi_inline_search_exit
    builtin typeset -ga preexec_functions
    preexec_functions+=(_govi_inline_preexec)
    return 0
}
_govi_inline_setup
