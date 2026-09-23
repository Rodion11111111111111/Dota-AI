FROM dart:3.13.3

WORKDIR /prilozhenie

COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY zapusk_servera.dart ./

CMD ["dart", "run", "zapusk_servera.dart"]
