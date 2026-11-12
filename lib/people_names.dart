/// Names a room without a name after its people, as Element X does:
/// "Alex", "Alex and Sam", "Alex, Sam and Kim", "Alex, Sam and 3 others".
String joinPeopleNames(List<String> names, {int others = 0}) {
  final people = [
    for (final name in names)
      if (name.trim().isNotEmpty) name.trim(),
  ];
  if (people.isEmpty) {
    return others > 0
        ? '$others ${others == 1 ? 'person' : 'people'}'
        : 'Empty chat';
  }
  if (others > 0) {
    return '${people.join(', ')} and $others ${others == 1 ? 'other' : 'others'}';
  }
  if (people.length == 1) return people.single;
  return '${people.sublist(0, people.length - 1).join(', ')} and ${people.last}';
}
