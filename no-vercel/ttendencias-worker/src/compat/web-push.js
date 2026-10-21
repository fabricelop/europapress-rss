// All push actions are deliberately disabled in the present TTendencias controllers.
// A legacy call must fail explicitly instead of simulating delivery.
export default {
  setVapidDetails(){throw Error("Notificaciones web push antiguas deshabilitadas");},
  async sendNotification(){throw Error("Notificaciones web push antiguas deshabilitadas");}
};
