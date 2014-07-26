ghnotify
========

Sends an automatic summary email of new commits for Github repository branches that you wish to monitor.

Configure the repositories (owner, repository and branch) to be monitored in ./ghnotify.conf:

######Example:
```
#owner/repository/branch        display name
raspberrypi/firmware/master     Raspberry Pi Firmware (master)
raspberrypi/linux/rpi-3.15.y    Raspberry Pi Linux (3.15.y)
OpenELEC/OpenELEC.tv/master     OpenELEC (master)
xbmc/xbmc/master                XBMC (master)
popcornmix/xbmc/newclock3       Popcornmix (newclock3)
```

Configure your github username and password in `~/.git.conf`:
```
GIT_USERNAME="your_username"
GIT_PASSWORD="your_password"
```

Github authentication is necessary to bypass [GitHub rate limiting](https://developer.github.com/v3/rate_limit/). If you don't plan on running this script very often, eg. one or twice an hour, then it may not be necessary to include authentication.

Configure your "to" email address in `~/.git.conf`:
```
EMAILTO="your.email@address.com"
```

When the script is run succesfully, it will record the latest SHA for each monitored repository in `./ghnotify.dat`.

The script has been tested with the msmtp MTA. Other MTAs may work, but are untested (patches welcome).

##Debugging

Interactively run the script with the `debug` parameter to avoid sending an email, and instead a file called `email.html` will be created which can be loaded in your web browser.

When run without any parameters an attempt will be made to send an email only if there has been one or more new commits.

##Dependencies

If it is not already installed on your system, you will need to install the `qprint` utility (`apt-get install qprint`) to encode quoted-printable text.

You will also require a Mail Transfer Agent, configured with your email account details. The script has been tested with `msmtp`.

##Sample Output

![sample](http://i225.photobucket.com/albums/dd119/MilhouseVH/ghnotify_zpsb0448750.png)
