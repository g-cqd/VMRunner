Let a token with the log capability read a container's output through the control service

The output file of a container machine could only be read on the disk. The
control service gets a read-only method, machines.log, with its own
capability, log, so a token can be given the log and nothing more.

The method follows the order of checks of the others: method, parameters,
token, capability, scope, whether the machine exists, agent access. It takes
no size. The app reads the last 64 KiB of the container's files off the main
actor and refuses a machine that is not a container, a machine whose agent
access is off, and every call while the organisation keeps the service off.
Whatever a machine returns is cut again to the last 64 KiB at a character
boundary, with truncated set, so an answer stays far below what the client
accepts even when every character needs escaping in JSON.

vmr control log prints the end of the log, at most the last --bytes (1 to
65536), and says first when earlier output is not shown; --json prints the
service's answer as it is, so a size with it is refused. The MCP server gets a fifth tool, machines_log, marked
read-only. The exposure summary of a container with agent access on says that
a token with the log capability can read what the container printed, and the
help says it where the capabilities and methods are listed.

