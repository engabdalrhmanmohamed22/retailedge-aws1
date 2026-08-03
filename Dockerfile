FROM php:8.2-apache

# Copy application source into the web root
COPY . /var/www/html/

# Enable commonly-needed Apache modules for a typical PHP app
RUN a2enmod rewrite

EXPOSE 80
