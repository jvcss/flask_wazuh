terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.16"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "sa-east-1"
}

# Selecionar a imagem AMAZON LINUX
data "aws_ami" "amzn_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# Criação de um conjunto de opções DHCP
resource "aws_vpc_dhcp_options" "dhcp_options" {
  domain_name         = "ec2.internal"
  domain_name_servers = ["AmazonProvidedDNS"]
}

# Associação das opções DHCP à VPC
resource "aws_vpc_dhcp_options_association" "dhcp_options_assoc" {
  vpc_id          = aws_vpc.main.id
  dhcp_options_id = aws_vpc_dhcp_options.dhcp_options.id
}

# Criação da VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "main_vpc"
  }
}

# Criação do Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# Criação da Sub-rede
resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true  # Isso garante que as instâncias na sub-rede obtenham IPs públicos automaticamente
  availability_zone       = "sa-east-1a" # A sub-rede será criada na zona de disponibilidade "sa-east-1a"
  enable_resource_name_dns_a_record_on_launch  = true # Isso garante que as instâncias na sub-rede obtenham registros DNS privados automaticamente

  tags = {
    Name = "main_subnet"
  }
}

# Criação da Tabela de rota dedicada
resource "aws_route_table" "main_route_table" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main_subnet_route_table"
  }
}

# Associa Tabela de rota dedicada ao Subnet
resource "aws_route_table_association" "main_subnet_association" {
  subnet_id         = aws_subnet.main.id
  route_table_id     = aws_route_table.main_route_table.id
}

# Criação de uma rota na tabela de rotas da subnet para o Internet Gateway
resource "aws_route" "internet_gateway_route" {
  route_table_id         = aws_route_table.main_route_table.id  # Assuming dedicated route table
  destination_cidr_block = "0.0.0.0/0"  # Rota para todos os IPs (Internet)
  gateway_id             = aws_internet_gateway.main.id  # ID do Internet Gateway associado à sua VPC
}

# Definir regras de acesso
resource "aws_security_group" "allow_ssh_http_https" {
  name        = "allow_ssh_http_https"
  description = "Allow SSH, HTTP, and HTTPS inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Para segurança, considere restringir ao seu IP
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Instalação da chave RSA para SSH
resource "aws_key_pair" "deployer_key" {
  key_name   = "deployer_key"
  public_key = file("C:/Users/vitim/.ssh/novarsa.pub")
}

# Criação da instância EC2
resource "aws_instance" "app_server" {
  ami                         = data.aws_ami.amzn_linux.id
  instance_type               = "t2.micro"
  key_name                    = aws_key_pair.deployer_key.key_name
  subnet_id                   = aws_subnet.main.id
  vpc_security_group_ids      = [aws_security_group.allow_ssh_http_https.id]
  associate_public_ip_address = true  # Isso garante que a instância tenha um IP público

  tags = {
    Name = "AppServerInstance7"
  }

  provisioner "local-exec" {
    command = "echo ${aws_instance.app_server.public_dns} > public_dns.txt"
  }
}

# Automatiza Continuos Deploy com Docker Compose
resource "null_resource" "install_dependencies" {
  provisioner "remote-exec" {
    inline = [
      "sudo yum update -y",
      "sudo yum install python3 -y",
      "sudo yum install python3-pip -y",
      "pip3 install Flask",
      "sudo yum install -y git",
      "git clone https://github.com/jvcss/flask_wazuh.git ~/app",
      "pip3 install gunicorn",
      "echo '[Unit]' | sudo tee /etc/systemd/system/flaskapp.service",
      "echo 'Description=Gunicorn instance to serve Flask app' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "echo 'After=network.target' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "echo '' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "echo '[Service]' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "echo 'User=ec2-user' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "echo 'Group=ec2-user' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "echo 'WorkingDirectory=/home/ec2-user/app' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "echo 'Environment=\"PATH=/usr/bin\"' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "echo 'ExecStart=/usr/local/bin/gunicorn -w 4 -b 0.0.0.0:80 app:app' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "echo '' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "echo '[Install]' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "echo 'WantedBy=multi-user.target' | sudo tee -a /etc/systemd/system/flaskapp.service",
      "sudo systemctl start flaskapp",
      "sudo systemctl enable flaskapp",
    ]
    connection {
      # usamos endereço publico DNS
      host = aws_instance.app_server.public_dns
      # usuario da instancia
      user = "ec2-user"
      # caminho da chave SSH privada
      private_key = file("C:/Users/vitim/.ssh/novarsa.pem")
    }
  }
  depends_on = [aws_instance.app_server]
}

