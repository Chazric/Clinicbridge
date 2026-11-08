import 'models.dart';

enum Permission {
  viewRecord,
  addEntry,
  verifyEntry,
  approveMachineContent,
  manageTasks,
  createHandoff,
  acceptHandoff,
  interpret,
  exportData,
  manageData,
  verifyIdentity,
}

class AccessDenied implements Exception {
  AccessDenied(this.role, this.permission);
  final Role role;
  final Permission permission;
  @override
  String toString() => '${role.label} is not allowed to ${permission.name}.';
}

class Rbac {
  static const Map<Role, Set<Permission>> matrix = {
    Role.physician: {
      Permission.viewRecord,
      Permission.addEntry,
      Permission.verifyEntry,
      Permission.approveMachineContent,
      Permission.manageTasks,
      Permission.createHandoff,
      Permission.acceptHandoff,
      Permission.interpret,
      Permission.exportData,
      Permission.verifyIdentity,
    },
    Role.nurse: {
      Permission.viewRecord,
      Permission.addEntry,
      Permission.verifyEntry,
      Permission.approveMachineContent,
      Permission.manageTasks,
      Permission.createHandoff,
      Permission.acceptHandoff,
      Permission.interpret,
      Permission.verifyIdentity,
    },
    Role.interpreter: {
      Permission.viewRecord,
      Permission.addEntry,
      Permission.interpret,
    },
    Role.admin: {
      Permission.exportData,
      Permission.manageData,
    },
    Role.viewer: {Permission.viewRecord},
  };

  static bool can(Role role, Permission p) => matrix[role]?.contains(p) ?? false;

  static void require(Role role, Permission p) {
    if (!can(role, p)) throw AccessDenied(role, p);
  }
}
