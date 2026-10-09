# ---- Build stage: compile the jar with Maven (no JDK / Maven needed on the host)
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package -DskipTests

# ---- Runtime stage: only a JRE + the jar
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
ENV SERVER_PORT=8081 \
    LOGS_FILE=/data/logs.jsonl
VOLUME /data
EXPOSE 8081
ENTRYPOINT ["java", "-jar", "app.jar"]
