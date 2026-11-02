# Build context: legacy-idp/. Tests run during the build, so a broken flow never becomes an image.
FROM maven:3.9.16-eclipse-temurin-25 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src src
RUN mvn -B -q verify

FROM eclipse-temurin:25.0.5_8-jre-noble
COPY --from=build /src/target/legacy-idp.jar /app/legacy-idp.jar
USER 1001
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/legacy-idp.jar"]
