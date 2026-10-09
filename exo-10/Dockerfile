# Étape 1 : compilation avec Maven + JDK 17 (rien à installer sur l'hôte)
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package -DskipTests

# Étape 2 : image d'exécution (JRE seul)
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/notes-app-1.0.0.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
