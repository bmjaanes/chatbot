FROM node:22-slim
WORKDIR /app
COPY . .
ENV NODE_ENV=production PORT=3000 DATA_DIR=/data
EXPOSE 3000
# /data must be a persistent volume: it holds every church's database.
CMD ["node", "--no-warnings", "server.js"]
