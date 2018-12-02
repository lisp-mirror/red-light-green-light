package main

import (
  "bytes"
  "encoding/json"
  "fmt"
  "log"
  "os"
  "time"
  "io/ioutil"
  "net/http"

  "github.com/urfave/cli"
)

func main() {
  var policy string

  app := cli.NewApp()

  app.Commands = []cli.Command{
    {
      Name:    "login",
      Aliases: []string{"l"},
      Usage:   "login to Red Light Green Light server",
      Action:  func(c *cli.Context) error {
        fmt.Println("login task: ", c.Args().First())
        return nil
      },
    },
    {
      Name:    "start",
      Aliases: []string{"s"},
      Usage:   "create a Player ID",
      Action:  func(c *cli.Context) error {

  	response, err := http.Get("http://localhost:8080/start")

	if err != nil {
		fmt.Print(err.Error())
		os.Exit(1)
	}
	
	responseData, err := ioutil.ReadAll(response.Body)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(string(responseData))

        return nil
      },
    },
    {
      Name:    "evaluate",
      Aliases: []string{"e"},
      Usage:   "evaluate test results",
      Flags: []cli.Flag{
        cli.StringFlag{
		Name: "policy",
		Value: "default",
		Usage: "evaluation policy",
		Destination: &policy,
		},
      },

      Action:  func(c *cli.Context) error {

      if c.NArg() == 0 {
            fmt.Print("ERROR: Missing report\n")
      	    return nil
	 }

      file, err := os.Open(c.Args().Get(0));
      defer file.Close();

      res, err := http.Post("http://localhost:8080/upload", "application/octet-stream", file);
      if err != nil {
      	 // panic(err)
	 }
	 defer res.Body.Close();
	 message, _ := ioutil.ReadAll(res.Body)
	 // check that it is OK?

          values := map[string]string{"name": file.Name(), "ref": string(message[:])}
	  jsonValue, _ := json.Marshal(values)

	 response, err := http.Post("http://localhost:8080/evaluate/", "application/json", bytes.NewBuffer(jsonValue))

	if err != nil {
		fmt.Print(err.Error())
		os.Exit(1)
	}
	
	responseData, err := ioutil.ReadAll(response.Body)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(string(responseData))

        return nil
      },
    },
  }

  app.Name = "rlgl"
  app.Copyright = "(c) 2018 Anthony Green"
  app.Compiled = time.Now()
  app.Authors = []cli.Author{
  	  cli.Author{
	    Name: "Anthony Green",
	    Email: "green@moxielogic.com",
	    },
	    }
  app.Usage = "Red Light Green Light"
  app.Action = func(c *cli.Context) error {

    return nil
  }

  err := app.Run(os.Args)
  if err != nil {
    log.Fatal(err)
  }
}