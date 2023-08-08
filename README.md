# Amazon Corretto OpenJDK를 사용한 Java  기반 애플리케이션 컨테이너 경량화

## 서론

컨테이너로 배포되는 애플리케이션은 컨테이너 이미지의 크기가 작을수록 빠르게 실행하고 확장할 수 있으며 이미지 보관 및 전송에 드는 비용이 절감됩니다. 특히 서버리스 컴퓨팅 엔진인 [AWS Fargate](https://aws.amazon.com/ko/fargate/)는 호스트 머신에 컨테이너 이미지를 캐싱하지 않기 때문에 애플리케이션을 실행할 때 컨테이너 이미지의 크기는 더 중요합니다. 그러나 Java 애플리케이션은 JVM(Java Virtual Machine)이 함께 배포되어야 하기 때문에 Go 언어와 같은 바이너리 형태로 배포되는 애플리케이션보다 컨테이너 이미지의 크기가 매우 큽니다. 이는 [경량화된 Distroless 이미지](https://github.com/GoogleContainerTools/distroless)를 사용해도 마찬가지입니다.

본 게시물에서는 [Amazon Web Services](https://aws.amazon.com/ko/)에서 제공하는 [Amazon Corretto Docker Image](https://hub.docker.com/_/amazoncorretto)의 [Amazon Corretto OpenJDK](https://aws.amazon.com/ko/corretto) 내장 CLI와 Docker Multistage Build 기능을 사용하여 Java 애플리케이션과 함께 배포되는 JVM의 크기를 최소화하는 방법에 대해 설명합니다.

## 솔루션 개요

본 게시물 에서는 [amazoncorretto:11.0.20-alpine](https://hub.docker.com/layers/library/amazoncorretto/11.0.20-alpine/images/sha256-7d950dfedd80da0f63b903040117b646c8752cf3a48bb52142e2aafb4af66479) 컨테이너 이미지에 경량화를 적용해 보았습니다. Distroless 이미지인  [gcr.io/distroless/java11-debian11](http://gcr.io/distroless/java11-debian11)은 비교를 위해 사용되었습니다. 두 이미지의 크기는 아래와 같이 각각 271MB, 204MB로 Distroless 이미지의 크기가 더 작은 것을 확인할 수 있습니다.

```
$ docker image ls
REPOSITORY                           TAG                IMAGE ID       CREATED       SIZE
amazoncorretto                       11.0.20-alpine     b2923f9506e4   5 days ago    271MB
gcr.io/distroless/java11-debian11    latest             acfbbcc6def5   N/A           204MB
```

Spring boot sample app을 기준으로 distroless와 amazoncorretto Docker 이미지로 빌드한 결과를 확인해 보겠습니다. 컨테이너 빌드에 사용한 Dockerfile은 아래와 같습니다.

```
# base image
FROM amazoncorretto:11.0.20-alpine
#FROM gcr.io/distroless/java11-debian11

# Copy sample-app.jar
COPY ./sample-app.jar /app/sample-app.jar
WORKDIR /app

EXPOSE 8080
ENTRYPOINT [ "/jre/bin/java", "-jar", "/app/app.jar" ]
```

샘플 애플리케이션을 포함하여 빌드한 이미지의 크기는 아래와 같습니다. Amazon Corretto 기반 이미지가 356 MB, Distroless 기반 이미지는 292 MB 입니다.

```
REPOSITORY                         TAG       IMAGE ID       CREATED        SIZE 
distroless-sample-api-jdk11        latest    6ace8643fa66   53 years ago   285MB
amazoncorretto-sample-api-jdk11    latest    c8960ae872c6   53 years ago   352MB
```

Amazon Corretto OpenJDK는 [50여개의 모듈](https://docs.oracle.com/en/java/javase/11/docs/api/index.html)로 구성되어 있습니다. 컨테이너를 빌드할 때 애플리케이션에서 사용하는 모듈만 컨테이너 이미지에 추가하여 JVM의 크기를 줄일 수 있습니다. 이를 위해 Amazon Corretto OpenJDK에 이미 포함되어 있는  [`jdeps`](https://wiki.openjdk.org/display/JDK8/Java+Dependency+Analysis+Tool)와 [`jlink`](https://openjdk.org/jeps/282) 를 사용합니다. 먼저 jdeps로 build된 결과물(jar 또는 war)의 Java 런타임 의존성을 분석하여 추출한 뒤 jlink로 필요한 모듈만 추가한 사용자 정의 JRE(Java Runtime Environment)를 만들어 [alpine:3.18.2](https://hub.docker.com/layers/library/alpine/3.18.2/images/sha256-25fad2a32ad1f6f510e528448ae1ec69a28ef81916a004d3629874104f8a7f70?context=explore) 이미지에 추가하는 형태로 Dockerfile을 구성할 수 있습니다.
[Image: Image.jpg]*그림 1. Docker Build Pipeline*

## jdeps, jlink로 JVM 크기 줄여보기

### jdeps를 사용하여 Java 런타임 모듈 의존성을 추출하기

우선 경량화에 적용할 sample-app에서 사용하는 모듈을 식별해 보겠습니다. local 환경에서 빌드된 결과물인 sample-app.jar의 압축을 해제하면 아래와 같은 폴더구조를 가지게 됩니다.

```
.sample-app
├── BOOT-INF
│   ├── classes ##빌드된 java 파일의 결과물(class)이 있습니다
│   └── lib     ##classes내에 class파일을 실행시키기 위한 jar libary가 있습니다.
├── META-INF
└── org
```

위 내용을 참고로 jdeps를 실행시켜 의존성이 있는 모듈을 추출하겠습니다. 좀 더 다양한 옵션을 확인하고자 한다면 [jdeps document](https://docs.oracle.com/en/java/javase/11/tools/jdeps.html) 를 참고하시기 바랍니다.

```
$ jdeps \
    --ignore-missing-deps \ ##의존성을 알 수 없는 모듈은 제외합니다
    --print-module-deps \ ##jlink에서 요구하는 포멧에 맞게 모듈 리스트를 출력합니다.
    -q \
    --recursive \ ##모든 runtime의 종속성을 재귀적으로 탐색합니다.
    --multi-release 11 \ ##의존성을 분석할 버전을 지칭합니다. jdeps는 모듈화가 적용된 jdk9이후로만 동작합니다.
    --class-path="./sample-app/BOOT-INF/lib/*" \
    --module-path="./sample-app/BOOT-INF/lib/*" \
    ./sample-app.jar
java.base,java.desktop,java.instrument,java.management,java.naming,java.prefs,java.rmi,java.scripting,java.security.jgss,java.security.sasl,java.sql,jdk.httpserver,jdk.jfr,jdk.unsupported
```

### jlink를 사용하여 사용자 정의 JRE 만들기

우리는 jdeps를 사용하여 애플리케이션이 의존하는 Java 런타임 모듈을 추출하는 데 성공했습니다. 다음으로 추출한 모듈로 사용자 정의 JRE를 만들어 보겠습니다.

```
$ jlink \
    --verbose \. ##상세한 추적을 활성화 하여 로깅합니다
    --add-modules java.base,java.desktop,java.instrument,java.management,java.naming,java.prefs,java.rmi,java.scripting,java.security.jgss,java.security.sasl,java.sql,jdk.httpserver,jdk.jfr,jdk.unsupported \
    --strip-debug \ ##디버그 정보를 제거합니다.
    --no-man-pages \ ##리소스의 man page를 제거합니다
    --no-header-files \
    --compress=2 \ ##리소스를 압축합니다. 0|1|2
    --output customjre
Providers:
  java.desktop provides java.net.ContentHandlerFactory used by java.base
  java.base provides java.nio.file.spi.FileSystemProvider used by java.base
  java.naming provides java.security.Provider used by java.base
  java.security.jgss provides java.security.Provider used by java.base
  java.security.sasl provides java.security.Provider used by java.base
  java.base provides java.util.random.RandomGenerator used by java.base
  java.desktop provides javax.print.PrintServiceLookup used by java.desktop
  java.desktop provides javax.print.StreamPrintServiceFactory used by java.desktop
  java.management provides javax.security.auth.spi.LoginModule used by java.base
  java.desktop provides javax.sound.midi.spi.MidiDeviceProvider used by java.desktop
  java.desktop provides javax.sound.midi.spi.MidiFileReader used by java.desktop
  java.desktop provides javax.sound.midi.spi.MidiFileWriter used by java.desktop
  java.desktop provides javax.sound.midi.spi.SoundbankReader used by java.desktop
  java.desktop provides javax.sound.sampled.spi.AudioFileReader used by java.desktop
  java.desktop provides javax.sound.sampled.spi.AudioFileWriter used by java.desktop
  java.desktop provides javax.sound.sampled.spi.FormatConversionProvider used by java.desktop
  java.desktop provides javax.sound.sampled.spi.MixerProvider used by java.desktop
  java.logging provides jdk.internal.logger.DefaultLoggerFinder used by java.base
  java.desktop provides sun.datatransfer.DesktopDatatransferService used by java.datatransfer
```

필요 모듈을 설치되어 있는 jdk에서 검색하여 특정 폴더로 packing 하였습니다. 생성된 customjre는 sample-app.jar를 실행하기 위한 최소 모듈만 담고 있으며 최소한의 cli만 포함된 상태로 생성 됩니다. 생성된 customjre의 크기는 아래와 같습니다.

```
$ du -sh customjre
 48M    customjre
```

기존에 local에 설치된 corretto-11.0.19의 크기와 비교해 보겠습니다.

```
$ du -sh corretto-11.0.19
299M    corretto-11.0.19
```

만약 customjre를 사용하지 않았다면, 251MB 가량의 불필요한 모듈과 파일을 가지고 java 애플리케이션이 실행 되었을 것 입니다. 감소율을 계산 해보자면 기존에 대비하여 약 83.96%의 용량을 절감 한 것을 볼 수 있습니다.

|corretto |customjre |감소율 |
|--- |--- |--- |
|299MB |48MB |83.95% |

*표 1. JRE 용량 비교*

### 컨테이너 경량화 Dockerfile 작성해보기

이제 jlink와 jdeps를 이용하여 컨테이너 이미지 크기를 경량화하는 Dockerfile을 작성해 보겠습니다. 아래의 Dockerfile은 Java 애플리케이션이 이미 jar 파일로 빌드된 상태임을 가정하고 작성되었습니다.

```
# base image to build a JRE
FROM amazoncorretto:11.0.20-alpine as *deps*

COPY ./sample-app.jar /app/sample-app.jar

RUN mkdir /app/unpacked && \
    cd /app/unpacked && \
    unzip ../sample-app.jar && \
    cd .. && \
    $JAVA_HOME/bin/jdeps \
    --ignore-missing-deps \
    --print-module-deps \
    -q \
    --recursive \
    --multi-release 11 \
    --class-path="./unpacked/BOOT-INF/lib/*" \
    --module-path="./unpacked/BOOT-INF/lib/*" \
    ./sample-app.jar > /deps.info

FROM amazoncorretto:11.0.20-alpine as *corretto**-**jdk*

RUN apk add --no-cache binutils

COPY --from=*deps* /deps.info /deps.info
# Build small JRE image
RUN $JAVA_HOME/bin/jlink \
         --verbose \
         --add-modules $(cat /deps.info) \
         --strip-debug \
         --no-man-pages \
         --no-header-files \
         --compress=2 \
         --output /customjre

# main app image
FROM alpine:3.18.2 ##또는 scratch
ENV *JAVA_HOME*=/jre
ENV *PATH*="${*JAVA_HOME*}/bin:${*PATH*}"

# copy JRE from the base image
COPY --from=*corretto**-**jdk* /customjre $*JAVA_HOME*

# Add app user
ARG *APPLICATION_USER*=appuser
RUN adduser --no-create-home -u 1000 -D $*APPLICATION_USER*

# Configure working directory
RUN mkdir /app && \
    chown -R $*APPLICATION_USER* /app

USER 1000

COPY --chown=1000:1000 ./sample-app.jar /app/sample-app.jar
WORKDIR /app

EXPOSE 8080
ENTRYPOINT [ "/jre/bin/java", "-jar", "/app/sample-app.jar" ]
```

멀티스테이지로 이루어진 빌드 단계를 설명하겠습니다.

* Stage 1
  * amazoncorretto:11.0.20-alpine 이미지를 Base 이미지로 사용하여 jdeps를 이용한 의존성 분석 및 분석 결과를 생성합니다.
* Stage 2
  * Stage 1과 동일한 이미지와 Stage 1에서 생성된 분석결과를 활용하여 jlink를 사용해 customjre 생성합니다.
* Stage 3
  * alpine:3.18.2 이미지를 base로 Stage 2에서 생성된 customjre를 사용하여 최종 이미지 생성. 보안을 위해 별도의 user를 생성하여 sample-app.jar를 실행 시킵니다.

Dockerfile로 build를 실행한 결과는 아래와 같습니다.

```
$ docker build -t sample-app:latest .
Sending build context to Docker daemon  81.22MB
Step 1/19 : FROM amazoncorretto:11.0.20-alpine as deps
 ---> 60ba21c1871e
Step 2/19 : COPY ./sample-app.jar /app/sample-app.jar
 ---> 5eac99c92ab7
.
.
.

$ docker images
REPOSITORY       TAG      IMAGE ID       CREATED          SIZE
sample-app       latest   9a6b09d7306b   18 seconds ago   142MB
```

이제 만들어진 sample-app container가 정상 작동 하는지 확인해 보겠습니다.

```
$ docker run sample-app:latest

  .   ____          _            __ _ _
 /\\ / ___'_ __ _ _(_)_ __  __ _ \ \ \ \
( ( )\___ | '_ | '_| | '_ \/ _` | \ \ \ \
 \\/  ___)| |_)| | | | | || (_| |  ) ) ) )
  '  |____| .__|_| |_|_| |_\__, | / / / /
 =========|_|==============|___/=/_/_/_/
 :: Spring Boot ::               (v2.7.10)

2023-07-24 08:28:07.142  INFO 1 --- [           main] c.e.d.ContainerBuildJibJdk11Application  : Starting ContainerBuildJibJdk11Application using Java 11.0.20 on a4f9e81da3d6 with PID 1 (/app/app.jar started by appuser in /app)
2023-07-24 08:28:07.144  INFO 1 --- [           main] c.e.d.ContainerBuildJibJdk11Application  : No active profile set, falling back to 1 default profile: "default"
2023-07-24 08:28:07.777  INFO 1 --- [           main] o.s.b.w.embedded.tomcat.TomcatWebServer  : Tomcat initialized with port(s): 8080 (http)
2023-07-24 08:28:07.794  INFO 1 --- [           main] o.apache.catalina.core.StandardService   : Starting service [Tomcat]
2023-07-24 08:28:07.794  INFO 1 --- [           main] org.apache.catalina.core.StandardEngine  : Starting Servlet engine: [Apache Tomcat/9.0.73]
2023-07-24 08:28:07.831  INFO 1 --- [           main] o.a.c.c.C.[Tomcat].[localhost].[/]       : Initializing Spring embedded WebApplicationContext
2023-07-24 08:28:07.831  INFO 1 --- [           main] w.s.c.ServletWebServerApplicationContext : Root WebApplicationContext: initialization completed in 652 ms
2023-07-24 08:28:08.276  INFO 1 --- [           main] o.s.b.w.embedded.tomcat.TomcatWebServer  : Tomcat started on port(s): 8080 (http) with context path ''
2023-07-24 08:28:08.285  INFO 1 --- [           main] c.e.d.ContainerBuildJibJdk11Application  : Started ContainerBuildJibJdk11Application in 1.435 seconds (JVM running for 1.753)
```

## 결과 확인하기

우리는 지금까지 Amazon Corretto OpenJDK에 포함된 jdeps, jlink와 Docker Multi Stage Build와 함께 사용하여 경량화된 Java 애플리케이션 컨테이너 이미지를 생성했습니다. 생성한 컨테이너 이미지 Layer를 [dive](https://github.com/wagoodman/dive) cli를 통해 확인한 결과는 아래와 같습니다.

```
Cmp   Size  Command 
    7.7 MB  FROM de8b86e33ae69ac
     53 MB  COPY /customjre /jre # buildkit
    4.7 kB  RUN |1 APPLICATION_USER=appuser /bin/sh -c adduser --no-create-home -u 1000 -D $APPLICATION_USER # buildkit
       0 B  RUN |1 APPLICATION_USER=appuser /bin/sh -c mkdir /app &&     chown -R $APPLICATION_USER /sample-app # buildkit
     81 MB  COPY ./sample-app.jar /app/sample-app.jar # buildkit
       0 B  WORKDIR /app
```

경량화를 하지 않은 amazoncorretto:11.0.20-alpine을 사용하여 빌드한 컨테이너 이미지 Layer와 비교해 보겠습니다.

```
Cmp   Size  Command 
    7.3 MB  FROM 9c8682f287ad45e
    267 MB  |1 version=11.0.20.8.1 /bin/sh -c wget -O /THIRD-PARTY-LICENSES-20200824.tar.gz https://corretto.aws/downloads/resou...
     81 MB  jib-gradle-plugin:3.3.1
       1 B  jib-gradle-plugin:3.3.1
    2.0 kB  jib-gradle-plugin:3.3.1
    3.1 kB  jib-gradle-plugin:3.3.1
```

경량화를 진행하기 전과 진행 후의 Container를 Amazon ECR에 push하여 결과를 비교해 보겠습니다.
[Image: Image.jpg]*그림 2. amazoncorretto 이미지 빌드 결과*
[Image: Image.jpg]*그림 3. distroless 이미지 빌드결과*
[Image: Image.jpg]*그림 4. customjre이용한 빌드 결과*

해당 결과를 표로 정리한다면 아래와 같습니다. Distroless 이미지 기반 애플리케이션 이미지보다 Amazon Corretto 기반 애플리케이션 이미지의 크기가 더 작은 것을 확인할 수 있습니다.

|BaseImage |General Build |Custom Build |Amazon ECR Size |Container Size 감소율 |
|--- |--- |--- |--- |--- |
|[amazoncorretto:11.0.20-alpine](https://hub.docker.com/layers/library/amazoncorretto/11.0.20-alpine/images/sha256-7d950dfedd80da0f63b903040117b646c8752cf3a48bb52142e2aafb4af66479) |356MB |142MB |114.87MB |60.11% |
|[gcr.io/distroless/java11-debian11](http://gcr.io/distroless/java11-debian11) |292MB |CLI 미포함 |156.08MB |amazoncorretto Customer Build구성 과 비교시 51.37% |
*표 2. 컨테이너 이미지별 빌드 결과 비교*

## 결론

이번 게시물 에서는 AWS에서 제공하는 Amazon Corretto OpenJDK를 사용하여 Java 애플리케이션 컨테이너의 크기를 경감시키는 방법을 소개했습니다.

Amazon Corretto OpenJDK와 함께 제공되는 jdeps, jlink를 사용하여 애플리케이션이 사용하지 않는 불필요한 런타임 모듈을 제거한 사용자 정의 JRE를 생성했습니다. 그리고 그 과정을 Multi-stage Dockerfile로 생성하여 컨테이너 이미지를 빌드할 때 자동 적용되도록 했습니다.

그 결과, 이미지 크기가 60% 경감되어 ECR 저장, 데이터 전송 비용, 애플리케이션 시작 및 scale out 시간이 40% 이상 개선될 것이라고 기대됩니다. 특히, Amazon ECS와 Amazon EKS 그리고 AWS Fargate와 함께 컨테이너 애플리케이션을 사용하는 경우 효율을 극대화될 것입니다. 이 게시물에서 진행한 Sample Code는 [github](https://github.com/aws-samples/corretto-jdk-spring-boot-size-optimization)에 있습니다.

* * *
## License

This library is licensed under the MIT-0 License. See the LICENSE file.
