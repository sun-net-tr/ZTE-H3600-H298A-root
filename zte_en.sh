#!/bin/bash

if [ -t 0 ] && [ -t 1 ]; then
    # Running in TTY - ensure output goes to current TTY
    exec 2>&1
    export TERM=${TERM:-linux}
fi

CURRENT_TTY=$(tty 2>/dev/null || echo "/dev/console")

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    NC=''
fi

ENABLE_MODE="root"
MODEL_TYPE=""

output_both() {
    echo -e "$1"
    # Also output to system console if different from current TTY
    if [ "$CURRENT_TTY" != "/dev/console" ] && [ -w "/dev/console" ]; then
        echo -e "$1" > /dev/console 2>/dev/null
    fi
}

print_banner() {
    clear
    output_both "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    output_both "${CYAN}║           ZTE UNIVERSAL ROOT ENABLER                     ║${NC}"
    output_both "${CYAN}║           Supports: H298A, H3600, H3600P & More          ║${NC}"
    output_both "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    output_both ""
}

print_status() {
    output_both "${YELLOW}[*]${NC} $1"
}

print_success() {
    output_both "${GREEN}[✓]${NC} $1"
}

print_error() {
    output_both "${RED}[✗]${NC} $1"
}

print_info() {
    output_both "${BLUE}[i]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

check_requirements() {
    print_status "Checking required services..."
    
    if ! command -v lighttpd &> /dev/null; then
        print_error "lighttpd is not installed. Please install it first:"
        print_info "apt-get install lighttpd"
        exit 1
    fi
    
    print_success "All required services found"
}

select_model() {
    output_both ""
    output_both "${YELLOW}Select Model Type:${NC}"
    output_both "  ${CYAN}1)${NC} H298A"
    output_both "  ${CYAN}2)${NC} H3600P"
    output_both "  ${CYAN}3)${NC} Try both"
    output_both ""
    
    echo -n "Choice [1-3]: "
    read -r model_choice < $CURRENT_TTY
    
    case $model_choice in
        1) MODEL_TYPE="H298A" ;;
        2) MODEL_TYPE="H3600P" ;;
        3) MODEL_TYPE="AUTO" ;;
        *) print_error "Invalid choice"; exit 1 ;;
    esac
}

cleanup_temp_files() {
    systemctl stop lighttpd 2>/dev/null
    
    if [ -f /etc/lighttpd/simula ]; then
        rm -f /etc/lighttpd/simula 2>/dev/null
    fi
    
    if [ -d /tmp/acs ]; then
        rm -rf /tmp/acs 2>/dev/null
    fi
}

exec_with_output() {
    local cmd="$1"
    local desc="$2"
    
    if output=$($cmd 2>&1); then
        return 0
    else
        if [ -n "$output" ]; then
            print_info "Output: $output"
        fi
        return 1
    fi
}

print_banner
check_root
check_requirements
select_model

NETWORK_IP="10.116.13.1"

print_status "Stopping services..."
if systemctl stop lighttpd 2>&1 | tee -a $CURRENT_TTY; then
    print_success "Services stopped"
else
    print_info "Services was not running"
fi

print_status "Configuring CGI..."
ln -sf /etc/lighttpd/conf-available/10-cgi.conf /etc/lighttpd/conf-enabled/ 2>&1 | tee -a $CURRENT_TTY
ln -sf /etc/lighttpd/conf-available/10-accesslog.conf /etc/lighttpd/conf-enabled/ 2>&1 | tee -a $CURRENT_TTY

cat > /etc/lighttpd/conf-enabled/10-cgi.conf << 'EOF'
server.modules += ( "mod_cgi" )

$HTTP["url"] =~ "^/.*" {
    cgi.assign = ( "/simula" => "" )
    alias.url = ( "" => "/etc/lighttpd/simula")
}
EOF
print_success "configured"

print_status "Creating handler..."
cat > /etc/lighttpd/simula << 'EOFSCRIPT'
#!/bin/bash

eval $HTTP_COOKIE

if [ -z "$session" ]; then
   session=$(date +'%s')
   mkdir -p /tmp/acs/$session
fi

if [ -f /tmp/acs/${session}/status ]; then
  status=$(cat /tmp/acs/${session}/status)
else
  status=1
fi

timestamp=$(date +'%Y%m%d_%H%M%S')
cat /dev/stdin > /tmp/acs/${session}/req${status}_${timestamp}.xml

echo "[$(date +'%H:%M:%S')] Session: $session | Status: $status | Request received" >> /tmp/acs/console.log

ENABLE_MODE=$(cat /tmp/acs/config_mode 2>/dev/null || echo "both")
MODEL_TYPE=$(cat /tmp/acs/config_model 2>/dev/null || echo "AUTO")

echo "Content-Type: text/xml"
[ -n "$session" ] && echo "Set-Cookie: session=$session"
echo ""

if [ "$status" == "1" ]; then
  echo "[$(date +'%H:%M:%S')] --> Sending InformResponse" >> /tmp/acs/console.log
  cat << 'XMLEOF'
<SOAP-ENV:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/encoding/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:cwmp="urn:dslforum-org:cwmp-1-0" xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<SOAP-ENV:Header>
<cwmp:ID SOAP:mustUnderstand="1">1</cwmp:ID>
<cwmp:NoMoreRequest>0</cwmp:NoMoreRequest>
</SOAP-ENV:Header>
<SOAP-ENV:Body>
<cwmp:InformResponse><MaxEnvelopes>1</MaxEnvelopes></cwmp:InformResponse>
</SOAP-ENV:Body>
</SOAP-ENV:Envelope>
XMLEOF

elif [ "$status" == "2" ]; then
  echo "[$(date +'%H:%M:%S')] --> Sending SetParameterValues (Root Access, Model: $MODEL_TYPE)" >> /tmp/acs/console.log
  
  PARAMS=""
  
  if [ "$MODEL_TYPE" == "H298A" ]; then
    PREFIX="X_TT"
  elif [ "$MODEL_TYPE" == "H3600P" ]; then
    PREFIX="X_TTG"
  else
    # Auto mode - try H298A format first
    PREFIX="X_TT"
  fi
  
  PARAMS="$PARAMS
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Configuration.Shell.Enable</n><Value xsi:type=\"xsd:boolean\">1</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Configuration.Shell.Password</n><Value xsi:type=\"xsd:string\">Baris123</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Users.User.2.Enable</n><Value xsi:type=\"xsd:boolean\">1</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Users.User.2.Username</n><Value xsi:type=\"xsd:string\">root</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Users.User.2.Password</n><Value xsi:type=\"xsd:string\">Baris123</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Users.User.2.RemoteAccessCapable</n><Value xsi:type=\"xsd:boolean\">1</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Users.User.2.LocalAccessCapable</n><Value xsi:type=\"xsd:boolean\">1</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.UserInterface.RemoteAccess.Enable</n><Value xsi:type=\"xsd:boolean\">1</Value></ParameterValueStruct>"
    
  PARAMS="$PARAMS
<ParameterValueStruct><n>InternetGatewayDevice.X_ZTE-COM_SSH.UserName</n><Value xsi:type=\"xsd:string\">root</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.X_ZTE-COM_SSH.Password</n><Value xsi:type=\"xsd:string\">Baris123</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.X_ZTE-COM_SSH.Port</n><Value xsi:type=\"xsd:unsignedInt\">22</Value></ParameterValueStruct>"
  
  cat << XMLEOF
<SOAP-ENV:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/encoding/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:cwmp="urn:dslforum-org:cwmp-1-0" xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<SOAP-ENV:Header>
<cwmp:ID SOAP:mustUnderstand="1">2</cwmp:ID>
<cwmp:NoMoreRequest>0</cwmp:NoMoreRequest>
</SOAP-ENV:Header>
<SOAP-ENV:Body>
<cwmp:SetParameterValues>
<ParameterList>
$PARAMS
</ParameterList>
<ParameterKey/>
</cwmp:SetParameterValues>
</SOAP-ENV:Body>
</SOAP-ENV:Envelope>
XMLEOF

elif [ "$status" == "3" ] && [ "$MODEL_TYPE" == "AUTO" ]; then
  # Auto mode - try alternative prefix if first failed
  echo "[$(date +'%H:%M:%S')] --> Trying alternative prefix (X_TTG)" >> /tmp/acs/console.log
  
  PREFIX="X_TTG"
  PARAMS=""
  
  PARAMS="$PARAMS
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Configuration.Shell.Enable</n><Value xsi:type=\"xsd:boolean\">1</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Configuration.Shell.Password</n><Value xsi:type=\"xsd:string\">Baris123</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Users.User.2.Enable</n><Value xsi:type=\"xsd:boolean\">1</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Users.User.2.Username</n><Value xsi:type=\"xsd:string\">root</Value></ParameterValueStruct>
<ParameterValueStruct><n>InternetGatewayDevice.${PREFIX}.Users.User.2.Password</n><Value xsi:type=\"xsd:string\">Baris123</Value></ParameterValueStruct>"
  
  cat << XMLEOF
<SOAP-ENV:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/encoding/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:cwmp="urn:dslforum-org:cwmp-1-0" xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<SOAP-ENV:Header>
<cwmp:ID SOAP:mustUnderstand="1">3</cwmp:ID>
<cwmp:NoMoreRequest>0</cwmp:NoMoreRequest>
</SOAP-ENV:Header>
<SOAP-ENV:Body>
<cwmp:SetParameterValues>
<ParameterList>
$PARAMS
</ParameterList>
<ParameterKey/>
</cwmp:SetParameterValues>
</SOAP-ENV:Body>
</SOAP-ENV:Envelope>
XMLEOF

else
  echo "[$(date +'%H:%M:%S')] --> Session completed" >> /tmp/acs/console.log
  echo ""
  
  if grep -q "<Status>0</Status>" /tmp/acs/${session}/req*_*.xml 2>/dev/null; then
    echo "[$(date +'%H:%M:%S')] *** CONFIGURATION APPLIED SUCCESSFULLY ***" >> /tmp/acs/console.log
    touch /tmp/acs/success
  fi
fi

status=$((status+1))
echo $status > /tmp/acs/${session}/status

EOFSCRIPT

chmod +x /etc/lighttpd/simula
print_success "created"

mkdir -p /tmp/acs
echo "$ENABLE_MODE" > /tmp/acs/config_mode
echo "$MODEL_TYPE" > /tmp/acs/config_model

mkdir -p /tmp/acs
chown www-data:www-data /tmp/acs
print_success "Directories created"

print_status "Starting services..."

print_info "Starting service..."
if systemctl restart lighttpd 2>&1 | tee -a $CURRENT_TTY; then
    print_success "Services started successfully"
else
    print_error "Failed to start Services"
fi

monitor_progress() {
    output_both ""
    output_both "${CYAN}══════════════════════════════════════════════════════════${NC}"
    output_both "${YELLOW}Monitoring Activity:${NC}"
    output_both "${CYAN}══════════════════════════════════════════════════════════${NC}"
    output_both "${MAGENTA}Mode: Root Access | Model: $MODEL_TYPE${NC}"
    output_both "${CYAN}══════════════════════════════════════════════════════════${NC}"
    
    > /tmp/acs/console.log
    
    tail -f /tmp/acs/console.log 2>/dev/null | while read line; do
        output_both "$line"
    done &
    TAIL_PID=$!
    
    TIMEOUT=180
    ELAPSED=0
    
    while [ $ELAPSED -lt $TIMEOUT ]; do
        if [ -f /tmp/acs/success ]; then
            output_both ""
            output_both "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
            output_both "${GREEN}║         CONFIGURATION APPLIED SUCCESSFULLY!              ║${NC}"
            output_both "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
            kill $TAIL_PID 2>/dev/null
            break
        fi
        sleep 1
        ELAPSED=$((ELAPSED + 1))
        
        if [ $((ELAPSED % 10)) -eq 0 ]; then
            output_both "${YELLOW}[*] Waiting for modem... ($ELAPSED/$TIMEOUT seconds)${NC}"
        fi
    done
    
    kill $TAIL_PID 2>/dev/null
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        output_both ""
        print_error "Timeout waiting for modem connection"
    fi
}

output_both ""
output_both "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
output_both "${GREEN}║                    SETUP COMPLETE                        ║${NC}"
output_both "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
output_both ""
output_both "${YELLOW}Configuration:${NC}"
output_both "  ${CYAN}Mode:${NC}  Root Access"
output_both "  ${CYAN}Model:${NC} $MODEL_TYPE"
output_both ""
output_both "${YELLOW}Next Steps:${NC}"
output_both "  1. ${CYAN}Disconnect${NC} modem's WAN cable"
output_both "  2. ${CYAN}Factory reset${NC} the modem (hold reset 10 seconds)"
output_both "  3. ${CYAN}Connect${NC} this server to modem's ${YELLOW}WAN port${NC}"
output_both "  4. ${CYAN}Power on${NC} the modem"
output_both "  5. ${CYAN}Wait${NC} for automatic configuration..."
output_both ""
output_both "${YELLOW}The script will now monitor for modem connection...${NC}"

monitor_progress

if [ -f /tmp/acs/success ]; then
    output_both ""
    output_both "${YELLOW}Root Access Information:${NC}"
    output_both "  ${CYAN}SSH:${NC}    ssh root@192.168.1.1"
    output_both "  ${CYAN}Web:${NC}    http://192.168.1.1"
    output_both "  ${CYAN}User:${NC}   root"
    output_both "  ${CYAN}Pass:${NC}   Baris123"
    output_both ""
    output_both "${GREEN}Root kullanıcısı ile tüm menülere erişebilirsiniz!${NC}"
    output_both "${GREEN}Kimsenin birsey bilmedigi yerde bir insan herseyi bilebilir!${NC}"
fi

cleanup_temp_files

if [ "$CURRENT_TTY" != "/dev/console" ]; then
    sync
fi