# Optional Fish wrapper. Not required: installing the launcher as
# ~/.local/bin/prime-agent is enough. This only forwards arguments unchanged.
function prime-agent --description 'Prime Agent in a managed container'
    command prime-agent-container $argv
end
