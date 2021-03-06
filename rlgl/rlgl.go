// rlgl.go - Copyright 2018, 2019, 2020  Anthony Green <green@moxielogic.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU Affero General Public License
// as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public
// License along with this program.  If not, see
// <http://www.gnu.org/licenses/>.

package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
	"mime/multipart"
	
	"github.com/fatih/color"
	"github.com/naoina/toml"
	"github.com/urfave/cli"
)

var (
	// FIXME: get version from git, as it done in rlgl-server.lisp
	VERSION = "undefined"
	red  = color.New(color.FgRed).SprintFunc()
	cyan = color.New(color.FgCyan).SprintFunc()
)

type Config struct {
	Host string
	Key string
	Proxy string
	ProxyAuth string
}

func NewConfig() *Config {
	return &Config{}
}

func output(s string) {
	fmt.Printf("%s %s\n", cyan("rlgl"), s)
}

func exitErr(err error) {
	output(red(err.Error()))
	os.Exit(2)
}

func (c *Config) Write(path string) {
	cfgdir := basedir(path)

	// create config dir if not exist
	if _, err := os.Stat(cfgdir); err != nil {
		err = os.MkdirAll(cfgdir, 0755)
		if err != nil {
			exitErr(fmt.Errorf("failed to initialize config dir [%s]: %s", cfgdir, err))
		}
	}

	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0644)
	if err != nil {
		exitErr(fmt.Errorf("failed to open config for writing: %s", err))
	}

	writer := toml.NewEncoder(file)
	err = writer.Encode(c)
	if err != nil {
		exitErr(fmt.Errorf("failed to write config: %s", err))
	}
}

// determine config path from environment
func getConfigPath() (path string, exists bool) {
	userHome, ok := os.LookupEnv("HOME")
	if !ok {
		exitErr(fmt.Errorf("$HOME not set"))
	}

	path = fmt.Sprintf("%s/.rlgl/config", userHome) // default path

	if xdgSupport() {
		xdgHome, ok := os.LookupEnv("XDG_CONFIG_HOME")
		if !ok {
			xdgHome = fmt.Sprintf("%s/.config", userHome)
		}
		path = fmt.Sprintf("%s/rlgl/config", xdgHome)
	}

	if _, err := os.Stat(path); err == nil {
		exists = true
	}

	return path, exists
}

func basedir(path string) string {
	parts := strings.Split(path, "/")
	return strings.Join((parts[0 : len(parts)-1]), "/")
}

// Test for environment supporting XDG spec
func xdgSupport() bool {
	re := regexp.MustCompile("^XDG_*")
	for _, e := range os.Environ() {
		if re.FindAllString(e, 1) != nil {
			return true
		}
	}
	return false
}

func setProxy (proxy string, auth string) {

	var transport *http.Transport;
	
	if proxy != "" {
		proxyUrl, err := url.Parse(proxy)
		if err != nil {
			log.Fatal(err)
		}
		if auth != "" {
			basicAuth := "Basic " + base64.StdEncoding.EncodeToString([]byte(auth))
			hdr := http.Header{}
			hdr.Add("Proxy-Authorization", basicAuth)
			transport = &http.Transport{
				Proxy: http.ProxyURL(proxyUrl),
				ProxyConnectHeader: hdr,
			}
		} else {
			transport = &http.Transport{
				Proxy: http.ProxyURL(proxyUrl),
			}
		}
		
		http.DefaultTransport = transport;
	}
}


func SendPostRequest (config *Config, url string, filename string, filetype string) []byte {
	file, err := os.Open(filename)
	
	if err != nil {
		log.Fatal(err)
	}
	defer file.Close()
	
	
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile(filetype, file.Name())
	
	if err != nil {
		log.Fatal(err)
	}
	
	io.Copy(part, file)
	writer.Close()
	request, err := http.NewRequest("POST", url, body)
	
	if err != nil {
		log.Fatal(err)
	}
	
	var bearer = "Bearer " + config.Key;
	request.Header.Add("Authorization", bearer)
	
	request.Header.Add("Content-Type", writer.FormDataContentType())
	client := &http.Client{}
	response, err := client.Do(request)
	
	if err != nil {
		log.Fatal(err)
	}
	defer response.Body.Close()
	
	content, err := ioutil.ReadAll(response.Body)
	
	if err != nil {
		log.Fatal(err)
	}
	
	return content
}

func main() {
	var policy string
	var player string
	var key string
	var proxy string
	var proxyauth string
	var title string
	var config Config

	cfgPath, cfgExists := getConfigPath()
	if !cfgExists {
		config.Write(cfgPath)
	} else {
		f, err := os.Open(cfgPath)
		if err != nil {
			exitErr(err)
		}
		defer f.Close()
		if err := toml.NewDecoder(f).Decode(&config); err != nil {
			exitErr(err)
		}
	}

	app := cli.NewApp()

	app.Commands = []cli.Command{
		{
			Name:    "login",
			Aliases: []string{"l"},
			Usage:   "login to Red Light Green Light server",
			Flags: []cli.Flag{
				cli.StringFlag{
					Name:        "key",
					Value:       "",
					Usage:       "API key",
					Destination: &key,
				},
				cli.StringFlag{
					Name:        "proxy",
					Value:       "",
					Usage:       "proxy URL (eg. http://HOST:PORT)",
					Destination: &proxy,
				},
				cli.StringFlag{
					Name:        "proxy-auth",
					Value:       "",
					Usage:       "proxy basic authentication (eg. USERNAME:PASSWORD)",
					Destination: &proxyauth,
				},
			},

			Action: func(c *cli.Context) error {

				if c.NArg() == 0 {
					exitErr(fmt.Errorf("Missing server URL"))
				}

				if key == "" {
					var slash string;
					if strings.HasSuffix(c.Args().First(), "/") {
						slash = "";
					} else {
						slash = "/";
					}
					exitErr(fmt.Errorf("Missing API key.  Generate a new one at %s%sget-api-key",
						c.Args().First(),
						slash))
				}

				setProxy(proxy, proxyauth);
				
				response, err := http.Get(fmt.Sprintf("%s/login", c.Args().First()))

				if err != nil {
					exitErr(err)
				}

				responseData, err := ioutil.ReadAll(response.Body)
				if err != nil {
					log.Fatal(err)
				}
				fmt.Println(string(responseData))
				config.Host = c.Args().First()
				config.Key = key
				config.Proxy = proxy
				config.ProxyAuth = proxyauth
				config.Write(cfgPath)
				return nil
			},
		},
		{
			Name:    "start",
			Aliases: []string{"s"},
			Usage:   "create a Player ID",
			Action: func(c *cli.Context) error {

				if (config.Host == "") || (config.Key == "") {
					exitErr(fmt.Errorf("Login to server first"))
				}

				setProxy(config.Proxy, config.ProxyAuth);

				var bearer = "Bearer " + config.Key;
				
				req, err := http.NewRequest("GET", fmt.Sprintf("%s/start", config.Host), nil)
				req.Header.Add("Authorization",	bearer)

				// Send req using http Client
				client := &http.Client{}
				resp, err := client.Do(req)
				if err != nil {
					exitErr(err)
				} else {
					defer resp.Body.Close()
					responseData, err := ioutil.ReadAll(resp.Body)
					if err != nil {
						log.Fatal(err)
					}
					fmt.Println(string(responseData))
				}

				return nil
			},
		},
		{
			Name:  "log",
			Usage: "log evaluations",
			Flags: []cli.Flag{
				cli.StringFlag{
					Name:        "id",
					Value:       "",
					Usage:       "player ID",
					Destination: &player,
				},
			},

			Action: func(c *cli.Context) error {

				if config.Host == "" {
					exitErr(fmt.Errorf("Login to server first"))
				}

				if player == "" {
					exitErr(fmt.Errorf("Missing player ID"))
				}

				// TODO: validate ID is a hex number
				
				if c.NArg() != 0 {
					exitErr(fmt.Errorf("Too many arguments"))
				}

				setProxy(config.Proxy, config.ProxyAuth);

				response, err := http.Get(fmt.Sprintf("%s/report-log?id=\"%s\"", config.Host, player))

				if err != nil {
					exitErr(err)
				}

				responseData, err := ioutil.ReadAll(response.Body)
				if err != nil {
					log.Fatal(err)
				}
				fmt.Print(string(responseData))

				return nil
			},
		},
		{
			Name:    "evaluate",
			Aliases: []string{"e"},
			Usage:   "evaluate test results",
			Flags: []cli.Flag{
				cli.StringFlag{
					Name:        "policy",
					Value:       "",
					Usage:       "evaluation policy",
					Destination: &policy,
				},
				cli.StringFlag{
					Name:        "id",
					Value:       "",
					Usage:       "player ID",
					Destination: &player,
				},
				cli.StringFlag{
					Name:        "title",
					Value:       "",
					Usage:       "report title",
					Destination: &title,
				},
			},

			Action: func(c *cli.Context) error {

				if (config.Host == "") || (config.Key == "") {
					exitErr(fmt.Errorf("Login to server first"))
				}

				if policy == "" {
					exitErr(fmt.Errorf("Missing policy"))
				}

				if player == "" {
					exitErr(fmt.Errorf("Missing player ID"))
				}

				if c.NArg() == 0 {
					exitErr(fmt.Errorf("Missing report"))
				}

				setProxy(config.Proxy, config.ProxyAuth);

				var n string;
				var name string;

				message := SendPostRequest (&config, fmt.Sprintf("%s/upload", config.Host), c.Args().Get(0), "bin");
				n = string(message)

				values := map[string]string{"policy": policy, "id": player, "name": name, "ref": n}
				if title != "" {
					values["title"] = title
				}

				jsonValue, _ := json.Marshal(values)

				request, err := http.NewRequest("POST", fmt.Sprintf("%s/evaluate", config.Host), bytes.NewBufferString(string(jsonValue)));
				if err != nil {
					log.Fatal(err)
				}
				var bearer = "Bearer " + config.Key;
				request.Header.Add("Authorization", bearer)
				request.Header.Add("Content-Type", "application/json");
				client := &http.Client{}
				response, err := client.Do(request)
				
				if err != nil {
					log.Fatal(err)
				}
				defer response.Body.Close()
				
				responseData, err := ioutil.ReadAll(response.Body)
				if err != nil {
					log.Fatal(err)
				}
				fmt.Print(string(responseData))
				
				if strings.HasPrefix(string(responseData), "GREEN:") {
					os.Exit(0)
				} else {
					if strings.HasPrefix(string(responseData), "RED:") {
						os.Exit(1)
					} else {
						os.Exit(2)
					}
				}
				return nil
			},
		},
	}

	app.Name = "rlgl"
	app.Version = VERSION
	app.Copyright = "(c) 2018-2020 Anthony Green"
	app.Compiled = time.Now()
	app.Authors = []cli.Author{
		cli.Author{
			Name:  "Anthony Green",
			Email: "green@moxielogic.com",
		},
	}
	app.Usage = "Red Light Green Light"
	app.Action = func(c *cli.Context) error {

		cli.ShowAppHelp(c)

		return nil
	}

	err := app.Run(os.Args)
	if err != nil {
		log.Fatal(err)
	}
}
