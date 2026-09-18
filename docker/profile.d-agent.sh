# Login-shell PATH for the agent host. See /etc/environment for the sshd/PAM
# side, which is what covers non-login `ssh host 'command'` invocations.
#
# These two prefixes live in the /home/dev volume, so anything a user installs
# into them (npm -g with a user prefix, pip --user, mise, cargo) persists
# across `portal update`.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) PATH="${HOME}/.local/bin:${PATH}" ;;
esac
case ":${PATH}:" in
    *":${HOME}/.npm-global/bin:"*) ;;
    *) PATH="${HOME}/.npm-global/bin:${PATH}" ;;
esac
export PATH
