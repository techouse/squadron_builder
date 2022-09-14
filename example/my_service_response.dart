import 'package:squadron/squadron_service.dart';

class MyServiceResponse<T> {
  MyServiceResponse._(this.result, this.sqId);

  MyServiceResponse(this.result) : sqId = Squadron.id ?? '<undefined>';

  factory MyServiceResponse.fromJson(Map json) =>
      MyServiceResponse._(json['r'], json['i']);

  final T result;
  final String sqId;

  Map toJson() => {'r': result, 'i': sqId};

  @override
  String toString() => '$sqId> $result';
}