#!/bin/bash

# This script is used to fix the audio problems on Legion Pro 7 16IRX8H.
# This is a combination of solutions from https://forums.lenovo.com/t5/Ubuntu/Ubuntu-and-legion-pro-7-16IRX8H-audio-issues/m-p/5210709

SERVICE_FIFO="/run/tas2781-fix.fifo"
SCRIPT_PATH="/usr/local/bin/tas2781-fix"
SERVICE_PATH="/etc/systemd/system/tas2781-fix.service"
SOCKET_PATH="/etc/systemd/system/tas2781-fix.socket"
USER_SERVICE_PATH="/etc/systemd/user/tas2781-fix.service"
DISABLE_POWERSAVE_MODPROBE="/etc/modprobe.d/audio_disable_powersave.conf"
DISABLE_PIPEWIRE_SUSPEND_CONF="/etc/wireplumber/wireplumber.conf.d/51-disable-suspension.conf"

uninstall() {
  if [ "$(id -u)" -eq 0 ]; then
    printf "This script must not be run as root.\n"
    exit 1
  fi

  if [ "$0" != "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
    # Call the uninstall function from the installed script. This allows older versions to uninstall themselves.
    "$SCRIPT_PATH" --uninstall
    sudo rm -f "$SCRIPT_PATH"
    return 0
  fi

  # stop running units if they exist
  if systemctl is-active --user --quiet tas2781-fix.service; then
    systemctl --user stop tas2781-fix.service
  fi

  if systemctl is-active --quiet tas2781-fix.socket; then
    sudo systemctl stop tas2781-fix.socket
  fi

  if systemctl is-active --quiet tas2781-fix.service; then
    sudo systemctl stop tas2781-fix.service
  fi

  # disable running units if they exist
  if systemctl is-enabled --user --quiet tas2781-fix.service; then
    systemctl --user disable tas2781-fix.service
  fi

  if systemctl is-enabled --quiet tas2781-fix.socket; then
    sudo systemctl disable tas2781-fix.socket
  fi

  sudo rm -f "$SERVICE_PATH"
  sudo rm -f "$SOCKET_PATH"
  sudo rm -f "$USER_SERVICE_PATH"
  sudo rm -f "$DISABLE_POWERSAVE_MODPROBE"
  sudo rm -f "$DISABLE_PIPEWIRE_SUSPEND_CONF"
  sudo rm -f "$SERVICE_FIFO"
}

install() {
  if [ "$(id -u)" -eq 0 ]; then
    printf "This script must not be run as root.\n"
    exit 1
  fi

  uninstall

  if [ "$0" != "$SCRIPT_PATH" ]; then
    sudo cp "$0" "$SCRIPT_PATH"
    sudo chmod 0755 "$SCRIPT_PATH"
  fi

  sudo mkdir -p "$(dirname "$SERVICE_PATH")"
  sudo mkdir -p "$(dirname "$SOCKET_PATH")"
  sudo mkdir -p "$(dirname "$USER_SERVICE_PATH")"
  sudo mkdir -p "$(dirname "$DISABLE_POWERSAVE_MODPROBE")"
  sudo mkdir -p "$(dirname "$DISABLE_PIPEWIRE_SUSPEND_CONF")"

  sudo tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=Run the tas2781-fix script when triggered
Requires=tas2781-fix.socket

[Service]
ExecStart=$SCRIPT_PATH --execute
Restart=no
StandardInput=socket
Type=oneshot
TimeoutSec=60
EOF

  sudo tee "$SOCKET_PATH" >/dev/null <<EOF
[Unit]
Description=Socket to trigger the tas2781 fix

[Socket]
ListenFIFO=$SERVICE_FIFO
FlushPending=yes
SocketMode=0442
Accept=no

[Install]
WantedBy=sockets.target
EOF

  sudo tee "$USER_SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=Trigger the tas2781-fix script on login and resume
After=pipewire.service
Before=wireplumber.service
Requires=pipewire.service

[Service]
ExecStart=$SCRIPT_PATH --start
Restart=no
Type=exec

[Install]
WantedBy=pipewire.service
EOF

  sudo tee "$DISABLE_POWERSAVE_MODPROBE" >/dev/null <<EOF
options snd_hda_intel power_save=0
options snd_hda_intel power_save_controller=N
blacklist snd_soc_avs
EOF

  sudo tee "$DISABLE_PIPEWIRE_SUSPEND_CONF" >/dev/null <<EOF
monitor.alsa.rules = [
  {
    matches = [
      {
        # Matches all sources
        node.name = "~alsa_input.*"
      },
      {
        # Matches all sinks
        node.name = "~alsa_output.*"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
      }
    }
  }
]
# bluetooth devices
monitor.bluez.rules = [
  {
    matches = [
      {
        # Matches all sources
        node.name = "~bluez_input.*"
      },
      {
        # Matches all sinks
        node.name = "~bluez_output.*"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
      }
    }
  }
]
EOF

  sudo systemctl daemon-reload
  systemctl --user daemon-reload

  sudo systemctl enable tas2781-fix.socket
  sudo systemctl start tas2781-fix.socket

  systemctl enable --user tas2781-fix.service
  systemctl start --user tas2781-fix.service
}

find_i2c_bus() {
  find /sys/bus/i2c/devices/*/* -type d -name 'i2c-TIAS2781\:00' -exec dirname {} \; | xargs basename | cut -f2 -d-
}

find_i2c_addresses() {
  local i2c_bus="$1"
  local line_number=0
  
  i2cdetect -y -r $i2c_bus | tail -n +2 | while read line; do 
    line="$(echo "$line" | sed 's/^.*://g')"
    for ((i=0; i<${#line}; i+=3)); do
        if [[ "${line:$i+1:2}" == "UU" || "${line:$i+1:2}" =~ [0-9a-fA-F]{2} ]]; then
            value=$((line_number * 16 + i / 3))
            echo $value
        fi
    done
    line_number=$((line_number + 1))
  done
}

execute_fix() {
  if [ "$(id -u)" -ne 0 ]; then
    printf "You must run this script as root.\n"
    exit 1
  fi

  local power_save_path="/sys/module/snd_hda_intel/parameters/power_save"
  local power_control_path="/sys/bus/i2c/drivers/tas2781-hda/i2c-TIAS2781:00/power/control"
  local i2c_bus=$(find_i2c_bus)
  local i2c_addr=($(find_i2c_addresses "$i2c_bus"))

  for value in ${i2c_addr[@]}; do
    # TAS2781 initialization
    # Data sheet: https://www.ti.com/lit/ds/symlink/tas2781.pdf
    
    # Get the channel configuration byte
    channel_config_byte=$(i2cget -f -y $i2c_bus $value 0x0a | xargs -I{} bash -c "echo \$(({}))") 
    # Get bits 4 and 5 of the channel configuration byte,
    # which represent whether we are using the left or right channel
    curent_channel=$((($channel_config_byte >> 4) & 0x03)) # 1 = Left channel, 2 = Right channel

    i2cset -f -y $i2c_bus $value 0x00 0x00 # Page 0x00
    i2cset -f -y $i2c_bus $value 0x7f 0x00 # Book 0x00
    i2cset -f -y $i2c_bus $value 0x01 0x01 # Software Reset
    sleep 0.001 # Add a 1ms delay

    i2cset -f -y $i2c_bus $value 0x0e 0xc4 0x40 i # TDM TX voltage sense enable with slot 4, curent sense enable with slot 0
    i2cset -f -y $i2c_bus $value 0x5c 0xd9 # CLK_PWRUD=1, DIS_CLK_HALT=0, CLK_HALT_TIMER=011, IRQZ_CLR=0, IRQZ_CFG=3
    i2cset -f -y $i2c_bus $value 0x60 0x10 # SBCLK_FS_RATIO=2
    
    if [ $current_channel -eq 1 ];
    then
      i2cset -f -y $i2c_bus $value 0x0a 0x1e # Left channel
    else
      i2cset -f -y $i2c_bus $value 0x0a 0x2e # Right channel
    fi

    i2cset -f -y $i2c_bus $value 0x0d 0x01 # TX_KEEPCY=0, TX_KEEPLN=0, TX_KEEPEN=0, TX_FILL=0, TX_OFFSET=000, TX_EDGE=1
    i2cset -f -y $i2c_bus $value 0x16 0x40 # AUDIO_SLEN=0, AUDIO_TX=0, AUDIO_SLOT=2

    i2cset -f -y $i2c_bus $value 0x00 0x01 # Page 0x01
    i2cset -f -y $i2c_bus $value 0x17 0xc8 # SARBurstMask=0

    i2cset -f -y $i2c_bus $value 0x00 0x04 # Page 0x04
    i2cset -f -y $i2c_bus $value 0x30 0x00 0x00 0x00 0x01 i # Merge Limiter and Thermal Foldback gains

    i2cset -f -y $i2c_bus $value 0x00 0x08 # Page 0x08
    i2cset -f -y $i2c_bus $value 0x18 0x00 0x00 0x00 0x00 i # 0dB volume
    i2cset -f -y $i2c_bus $value 0x28 0x40 0x00 0x00 0x00 i # Unmute

    i2cset -f -y $i2c_bus $value 0x00 0x0a # Page 0x0a
    i2cset -f -y $i2c_bus $value 0x48 0x00 0x00 0x00 0x00 i # 0dB volume
    i2cset -f -y $i2c_bus $value 0x58 0x40 0x00 0x00 0x00 i # Unmute

    i2cset -f -y $i2c_bus $value 0x00 0x00 # Page 0x00
    i2cset -f -y $i2c_bus $value 0x02 0x00 # Play audio, power up with playback, IV enabled
    sleep 0.001 # Add a 1ms delay
  done

  until [ -e "$power_save_path" ] && [ -e "$power_control_path" ]; do
    sleep 1
  done

  # Disable snd_hda_intel power saving
  printf "0" > "$power_save_path"

  # Disable runtime suspend/resume for tas2781
  printf "on" > "$power_control_path"
}

trigger_fix() {
  local count=0
  
  echo "Waiting for the tas2781-fix socket to become available."
  while ! systemctl is-active --quiet tas2781-fix.socket; do
    if [ $count -eq 60 ]; then
      printf "Failed to trigger the tas2781-fix script.\n"
      exit 1
    fi

    sleep 1
    count=$(($count + 1))
  done

  echo "Triggering the tas2781-fix script."

  # Poke the socket to trigger the tas2781-fix script. 
  # This allows a non-root user to trigger the script.
  echo "" > "$SERVICE_FIFO"
}

run_fix_service() {
  local unarray='.[]'
  local state_changed='select(.info["change-mask"]|index("state"))'
  local running='select(.info.state=="running")'
  local snd_hda_intel='select(.info.props["alsa.driver_name"]=="snd_hda_intel")'

  pw-dump -m | stdbuf -oL jq -cM "$unarray | $snd_hda_intel | $state_changed | $running" | while IFS=$'\n' read -r; do
    trigger_fix
  done
}

check-dependencies() {
  if ! command -v i2cset &>/dev/null; then
    printf "The i2c-tools package is required to run this script.\n"
    exit 1
  fi
  
  if ! command -v jq &>/dev/null; then
    printf "The jq package is required to run this script.\n"
    exit 1
  fi

  if ! command -v pw-dump &>/dev/null; then
    printf "The pipewire package is required to run this script.\n"
    exit 1
  fi
}

parse_args() {
  check-dependencies

  case "$1" in
    --execute)
      execute_fix
      exit 0
      ;;
    --start)
      run_fix_service
      exit 0
      ;;
    --install)
      install
      printf "tas2781-fix has been installed successfully.\n"
      printf "Please reboot your system to apply the changes.\n"
      exit 0
      ;;
    --uninstall)
      uninstall
      sudo rm -f "$SCRIPT_PATH"
      printf "tas2781-fix has been uninstalled successfully.\n"
      printf "Please reboot your system to apply the changes.\n"
      exit 0
      ;;
    *)
      printf "Invalid argument: $1\n"
      exit 1
      ;;
  esac
}

parse_args "$@"
