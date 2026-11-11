
FROM nginx:alpine

# Copy the Hello World application into Nginx
COPY index.html /usr/share/nginx/html/index.html

# Expose HTTP port
EXPOSE 80

# Start Nginx
CMD ["nginx", "-g", "daemon off;"]