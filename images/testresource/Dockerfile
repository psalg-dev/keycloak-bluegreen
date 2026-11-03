# Build context: testresource/. Tests run during the build (JVM), so a broken behaviour never becomes an image.
# Default: GraalVM native image on distroless (glibc). MODE=jvm: plain JVM image for debugging:
#   docker build --build-arg MODE=jvm -f images/testresource/Dockerfile testresource
ARG MODE=native

FROM ghcr.io/graalvm/native-image-community:25i4-25.0.4.1.1-ol10-20260922 AS build
COPY --from=maven:3.9.16-eclipse-temurin-25 /usr/share/maven /usr/share/maven
ENV PATH=/usr/share/maven/bin:$PATH
WORKDIR /src
COPY pom.xml .
RUN mvn -B -q -Pnative dependency:go-offline
COPY src src
ARG MODE
# native:compile forks `package` (tests, Spring AOT), then runs native-image (heap: pom property native.xmx).
# Not -q: native-image's summary (build time, peak RSS) stays in the build log.
RUN if [ "$MODE" = native ]; then mvn -B -ntp -Pnative native:compile; else mvn -B -q verify; fi

FROM eclipse-temurin:25.0.5_8-jre-noble AS jvm
COPY --from=build /src/target/testresource.jar /app/testresource.jar
USER 1001
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/testresource.jar"]

FROM gcr.io/distroless/base-debian13:nonroot@sha256:9039a88709bcc2bacf5a2faac331d65dd6840f763f225ad9594cc0c67bcd0fba AS native
COPY --from=build /src/target/testresource /app/testresource
EXPOSE 8080
ENTRYPOINT ["/app/testresource"]

FROM ${MODE}
