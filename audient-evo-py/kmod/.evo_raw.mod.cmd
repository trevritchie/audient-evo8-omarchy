savedcmd_evo_raw.mod := printf '%s\n'   evo_raw.o | awk '!x[$$0]++ { print("./"$$0) }' > evo_raw.mod
