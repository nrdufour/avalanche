package collector

import "fmt"

// Common port to service name mappings.
var portServices = map[int]string{
	// Well-known ports
	20:    "FTP-DATA",
	21:    "FTP",
	22:    "SSH",
	23:    "Telnet",
	25:    "SMTP",
	53:    "DNS",
	67:    "DHCP",
	68:    "DHCP",
	69:    "TFTP",
	80:    "HTTP",
	88:    "Kerberos",
	110:   "POP3",
	123:   "NTP",
	135:   "RPC",
	137:   "NetBIOS",
	138:   "NetBIOS",
	139:   "NetBIOS",
	143:   "IMAP",
	161:   "SNMP",
	162:   "SNMP",
	389:   "LDAP",
	443:   "HTTPS",
	445:   "SMB",
	465:   "SMTPS",
	500:   "IKE",
	514:   "Syslog",
	515:   "LPD",
	520:   "RIP",
	587:   "SMTP",
	636:   "LDAPS",
	853:   "DoT",
	873:   "Rsync",
	993:   "IMAPS",
	995:   "POP3S",
	1080:  "SOCKS",
	1194:  "OpenVPN",
	1433:  "MSSQL",
	1434:  "MSSQL",
	1521:  "Oracle",
	1723:  "PPTP",
	1883:  "MQTT",
	2049:  "NFS",
	2222:  "SSH",
	3306:  "MySQL",
	3389:  "RDP",
	3478:  "STUN",
	4500:  "IPsec",
	5060:  "SIP",
	5061:  "SIPS",
	5222:  "XMPP",
	5432:  "PostgreSQL",
	5900:  "VNC",
	5901:  "VNC",
	6379:  "Redis",
	6443:  "K8s API",
	6667:  "IRC",
	6697:  "IRC",
	8080:  "HTTP-Alt",
	8443:  "HTTPS-Alt",
	8883:  "MQTTS",
	9000:  "Portainer",
	9090:  "Prometheus",
	9100:  "Node-Exp",
	9418:  "Git",
	10250: "Kubelet",
	11211: "Memcached",
	27017: "MongoDB",
	51820: "WireGuard",
}

// GetServiceName returns the service name for a port, or empty string if unknown.
func GetServiceName(port int) string {
	if name, ok := portServices[port]; ok {
		return name
	}
	return ""
}

// FormatPort returns a formatted port string with service name if known.
// Example: "443 (HTTPS)" or "12345" if unknown.
func FormatPort(port int) string {
	if port <= 0 {
		return ""
	}
	if name := GetServiceName(port); name != "" {
		return fmt.Sprintf("%d (%s)", port, name)
	}
	return fmt.Sprintf("%d", port)
}

// FormatPortWithProtocol returns a formatted port string with protocol context.
// Some ports have different meanings based on protocol (e.g., 53 TCP vs UDP).
func FormatPortWithProtocol(port int, protocol string) string {
	if port <= 0 {
		return ""
	}
	if name := GetServiceName(port); name != "" {
		return fmt.Sprintf("%d (%s)", port, name)
	}
	return fmt.Sprintf("%d", port)
}
