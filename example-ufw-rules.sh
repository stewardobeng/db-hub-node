#!/usr/bin/env bash
# Example: allow only a trusted office IP to reach MariaDB remotely
ufw allow from 203.0.113.10 to any port 3306 proto tcp
ufw status verbose
