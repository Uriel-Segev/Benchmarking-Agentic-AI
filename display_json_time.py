import json
import sys
import matplotlib.pyplot as plt

def main():
    # check if the usage was correct, has to provide a json file as command line argument
    if len(sys.argv) < 2:
        print("Not enough args, Usage: display_json_time.py file_name.json")
        sys.exit(1)
    
    # extract the json file name
    file_name = sys.argv[1]


    try:
        #open the file and load it as json
        with open(file_name, 'r') as file:
            #get json data
            data = json.load(file)

            
            avg_boot_time = [] #declare avg boot time array
            avg_solution_time = [] #declare avg solution time array
            avg_shutdown_time = [] #declare avg shutdown time array
            instance_count = [] #declare instance count for each run (collection of data)
            completion_rate = [] #declare array for amount of VMs that completed the task

            #loop through each run
            for i in range(len(data["runs"])):
                #if data wasn't collected (likely crashed) then ignore it
                if "timing_summary" in data["runs"][i]:
                    #fill in values (averages)
                    avg_boot_time.append(data["runs"][i]["timing_summary"]["boot_time_s"]["avg"])
                    avg_solution_time.append(data["runs"][i]["timing_summary"]["solution_time_s"]["avg"])
                    avg_shutdown_time.append(data["runs"][i]["timing_summary"]["shutdown_time_s"]["avg"])
                    instance_count.append(str(data["runs"][i]["vm_count"]))
                    completion_rate.append((data["runs"][i]["completed"] / (data["runs"][i]["total_instances"])) * 100)            

            #average boot time plot:
            fig, ax1 = plt.subplots()
            ax1.bar(instance_count, avg_boot_time)
            ax1.set_xlabel('# of instances')
            ax1.set_ylabel('avg boot time')
            
            ax2 = ax1.twinx()
            ax2.plot(instance_count, completion_rate, color='red', marker='o')
            ax2.set_ylabel('completion rate %')
            
            plt.title('Boot Time vs. # Instances')
            plt.show()

            #average solution time plot:
            fig, ax1 = plt.subplots()
            ax1.bar(instance_count, avg_solution_time)
            ax1.set_xlabel('# of instances')
            ax1.set_ylabel('avg solution time')

            ax2 = ax1.twinx()
            ax2.plot(instance_count, completion_rate, color='red', marker='o')
            ax2.set_ylabel('completion rate %')

            plt.title('Solution Time vs. Instances')
            plt.show()


            #average shutdown time plot:
            fig, ax1 = plt.subplots()           
            ax1.bar(instance_count, avg_shutdown_time)
            ax1.set_xlabel('# of instances')
            ax1.set_ylabel('avg shutdown time')

            ax2 = ax1.twinx()
            ax2.plot(instance_count, completion_rate, color='red', marker='o')
            ax2.set_ylabel('completion rate %')

            plt.title('Shutdown Time vs. Instances')
            plt.show()

                
    #file not found error
    except FileNotFoundError:
        print(f"File {file_name} not found")
    #json decoder error
    except json.JSONDecodeError:
        print(f"Error: could not decode json file")
    #general error, display it
    except Exception as e:
        print(f"An error has occured: {e}")


if __name__ == "__main__":
    main()