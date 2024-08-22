import smtplib, sys, os
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

email_host = str("email-smtp.us-west-2.amazonaws.com")
from_addr = str("devportal@webmethods-int.io")
to_addr = str("rajh@softwareag.com")
email_user = str("AKIASQWECSGU5OXI7ZO6")
email_passwd = str("BJ8JZrgiWA8nsfeltVbPqpx+ldwwv5FzHrqe/VB7IoLS")
subject= str(sys.argv[1])
body= str(sys.argv[2])

server = smtplib.SMTP(email_host, 587)
msg = MIMEText(body)
msg['From'] = from_addr
msg['To'] = to_addr
msg['Subject'] = subject

server.ehlo()
server.starttls()
server.ehlo()
server.login(email_user, email_passwd)
server.sendmail(from_addr, to_addr.split(','), msg.as_string())
