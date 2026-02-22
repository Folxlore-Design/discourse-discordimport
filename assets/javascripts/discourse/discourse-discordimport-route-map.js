export default {
  resource: "admin.adminPlugins",
  path: "/plugins",
  map() {
    this.route("discord-import");
  },
};
